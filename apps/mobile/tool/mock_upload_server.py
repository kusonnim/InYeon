"""Loopback-only contract test server for the Android library, uploads, and notifications."""

import argparse
import base64
from copy import deepcopy
from datetime import datetime, timezone
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
from threading import Lock
import time
from urllib.parse import parse_qs, urlsplit
from uuid import UUID, uuid4, uuid5, NAMESPACE_URL

from jsonschema import Draft202012Validator, FormatChecker
import yaml


PUBLISHABLE_KEY = "sb_publishable_itda_mock"
PASSWORD = "itda-test-only"
USERS = {email: str(uuid5(NAMESPACE_URL, email)) for email in ("a@example.test", "b@example.test")}
OPENAPI = Path(__file__).resolve().parents[3] / "contracts" / "openapi.yaml"


def utc(seconds):
    return datetime.fromtimestamp(seconds, timezone.utc).isoformat().replace("+00:00", "Z")


def segment(value):
    return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")


def error(status, code, **fields):
    return status, {"error": {
        "code": code, "message": "Synthetic test response", "request_id": str(uuid4()), **fields,
    }}


def matches_type(data, media_type):
    if media_type == "image/webp":
        return data[:4] == b"RIFF" and data[8:12] == b"WEBP"
    if media_type == "text/plain":
        try:
            data.decode("utf-8")
            return True
        except UnicodeDecodeError:
            return False
    return data.startswith({
        "image/jpeg": b"\xff\xd8\xff", "image/png": b"\x89PNG\r\n\x1a\n", "application/pdf": b"%PDF-",
    }[media_type])


class MockUploadServer(ThreadingHTTPServer):
    def __init__(self, args):
        super().__init__(("127.0.0.1", args.port), Handler)
        self.args = args
        self.lock = Lock()
        self.tokens = {}
        self.refresh_tokens = {}
        self.assets = {}
        self.contents = {}
        self.preferences = {}
        self.cursors = {}
        self.feed = {}
        self.feed_tokens = {}
        self.feed_offsets = {}
        self.hold_reads = set()
        self.receipts = {}
        self.expire_next_capability = args.expire_first_capability
        self.hold_text = args.hold_source_text
        document = yaml.safe_load(OPENAPI.read_text(encoding="utf-8"))
        self.validators = {
            name: Draft202012Validator(
                {"$ref": f"#/components/schemas/{name}", "components": document["components"]},
                format_checker=FormatChecker(),
            )
            for name in (
                "ContentCreate", "Content", "ContentPage", "ContentPatch", "AssetUploadCreate", "AssetUpload",
                "AssetComplete", "NotificationEvent", "NotificationRestore", "NotificationResult", "ErrorResponse",
                "Preferences", "PreferencesPatch", "SyncPage",
            )
        }
        catalog = json.loads((OPENAPI.parent / "examples" / "catalog.json").read_text(encoding="utf-8"))
        self.analysis_examples = {
            item["analysis_status"]: item["analysis"]
            for item in catalog["items"] if item["analysis"] is not None
        }
        if getattr(args, "seed_catalog", False):
            for fixture in catalog["items"]:
                item = {**deepcopy(fixture), "user_id": USERS["a@example.test"]}
                self.validators["Content"].validate(item)
                self.contents[item["id"]] = item
                self.emit(item["user_id"], "content", item["id"], item["id"])

    def emit(self, owner, entity_type, entity_id, content_id=None, operation="upsert"):
        events = self.feed.setdefault(owner, [])
        events.append({
            "sequence": str(9007199254740992 + len(events) + 1),
            "entity_type": entity_type, "entity_id": entity_id, "content_id": content_id,
            "operation": operation, "occurred_at": utc(time.time()),
        })

    def sync_token(self, owner, offset):
        tokens = self.feed_tokens.setdefault(owner, {})
        if offset not in tokens:
            token = str(uuid4())
            tokens[offset] = token
            self.feed_offsets.setdefault(owner, {})[token] = offset
        return tokens[offset]

    def handle_error(self, _request, _client_address):
        print("Mock request failed validation or connection handling.", flush=True)

    def session(self, email):
        user = USERS[email]
        expires = int(time.time()) + 3600
        claims = segment({"sub": user, "role": "authenticated", "exp": expires, "jti": str(uuid4())})
        token = f'{segment({"alg": "HS256"})}.{claims}.mock'
        refresh = str(uuid4())
        self.tokens[token] = (user, expires)
        self.refresh_tokens[refresh] = email
        return {
            "access_token": token, "refresh_token": refresh, "token_type": "bearer",
            "expires_in": 3600, "expires_at": expires, "user": {"id": user, "email": email},
        }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        # HTTP paths for private storage include a capability.
        pass

    def respond(self, status, value):
        if isinstance(value.get("error"), dict):
            self.server.validators["ErrorResponse"].validate(value)
        payload = json.dumps(value).encode()
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def read_payload(self, limit):
        length = int(self.headers.get("Content-Length", 0))
        if length < 0 or length > limit:
            raise ValueError("Invalid request size")
        return self.rfile.read(length)

    def read_json(self):
        payload = self.read_payload(1024 * 1024)
        return json.loads(payload) if payload else None

    def do_POST(self):
        path = urlsplit(self.path)
        try:
            body = self.read_json()
        except ValueError:
            self.respond(*error(422, "validation_error"))
            return
        with self.server.lock:
            if path.path == "/auth/v1/token":
                status, value = self.token(parse_qs(path.query).get("grant_type", [""])[0], body)
                hold = False
            elif path.path.startswith("/mock/analysis/"):
                status, value = self.mock_analysis(path.path.removeprefix("/mock/analysis/"), body)
                hold = False
            elif path.path == "/mock/sync":
                status, value = self.mock_sync(body)
                hold = False
            else:
                status, value, hold = self.api(path.path, body)
        if hold:
            print("Mock content committed. First acknowledgment is delayed.", flush=True)
            time.sleep(75)
        self.respond(status, value)

    def do_GET(self):
        path = urlsplit(self.path)
        query = parse_qs(path.query, keep_blank_values=True)
        with self.server.lock:
            if path.path == "/v1/contents":
                status, value = self.list_contents(query)
            elif path.path == "/v1/sync":
                status, value = self.sync_changes(query)
            elif path.path == "/v1/preferences":
                status, value = self.preferences_request()
            else:
                status, value = self.content_request(path.path)
            holder = (self.current_owner(), path.path)
            held = holder in self.server.hold_reads and status == 200
            if held:
                self.server.hold_reads.remove(holder)
        if held:
            label = "catalog page" if path.path == "/v1/contents" else "content read"
            print(f"Mock {label} held after capturing its response.", flush=True)
            time.sleep(20)
        self.respond(status, value)

    def do_PATCH(self):
        try:
            body = self.read_json()
        except ValueError:
            self.respond(*error(422, "validation_error"))
            return
        path = urlsplit(self.path).path
        preferences = path == "/v1/preferences"
        schema = "PreferencesPatch" if preferences else "ContentPatch"
        if not self.server.validators[schema].is_valid(body):
            self.respond(*error(422, "validation_error"))
            return
        with self.server.lock:
            status, value = self.preferences_request(body) if preferences else self.content_request(path, body)
        self.respond(status, value)

    def current_owner(self):
        auth = self.headers.get("Authorization", "")
        session = self.server.tokens.get(auth.removeprefix("Bearer ")) if auth.startswith("Bearer ") else None
        return session[0] if session is not None and session[1] > time.time() else None

    def owned(self, owner, identifier):
        item = self.server.contents.get(identifier)
        return item if item is not None and item["user_id"] == owner else None

    def sync_changes(self, query):
        owner = self.current_owner()
        if owner is None:
            return error(401, "unauthorized")
        try:
            limit = int(query.get("limit", ["20"])[0])
        except ValueError:
            return error(422, "validation_error")
        if not 1 <= limit <= 100:
            return error(422, "validation_error")
        limit = min(limit, getattr(self.server.args, "sync_page_size", 100))
        cursor = query.get("cursor", [None])[0]
        offset = 0 if cursor is None else self.server.feed_offsets.get(owner, {}).get(cursor)
        if offset is None:
            return error(400, "invalid_cursor")
        events = self.server.feed.get(owner, [])
        replay = getattr(self.server.args, "replay_sync_prefix", False)
        prefix = events[offset - 1:offset] if replay and offset and limit > 1 else []
        new = events[offset:offset + limit - len(prefix)]
        end = offset + len(new)
        visible = prefix + new
        if replay and new and len(visible) < limit:
            visible.append(new[-1])
        page = {
            "events": deepcopy(visible), "next_cursor": self.server.sync_token(owner, end),
            "has_more": end < len(events),
        }
        self.server.validators["SyncPage"].validate(page)
        return 200, page

    def preferences_request(self, patch=None):
        owner = self.current_owner()
        if owner is None:
            return error(401, "unauthorized")
        stamp = utc(time.time())
        value = self.server.preferences.setdefault(owner, {
            "user_id": owner, "interests": [], "explicit_preferences": [], "mbti": None,
            "version": 1, "created_at": stamp, "updated_at": stamp,
        })
        if patch is not None:
            if patch["expected_version"] != value["version"]:
                return error(409, "version_conflict", current_version=value["version"])
            value.update({key: val for key, val in patch.items() if key != "expected_version"})
            value.update(version=value["version"] + 1, updated_at=stamp)
            self.server.emit(owner, "preferences", owner)
        self.server.validators["Preferences"].validate(value)
        return 200, deepcopy(value)

    def mock_sync(self, body):
        owner = self.current_owner()
        if owner is None:
            return error(401, "unauthorized")
        action = body.get("action") if isinstance(body, dict) else None
        if action == "expire_cursor":
            self.server.feed_tokens.pop(owner, None)
            self.server.feed_offsets.pop(owner, None)
        elif action == "hold_next_catalog":
            self.server.hold_reads.add((owner, "/v1/contents"))
        elif action in ("hold_next_content", "delete_content"):
            identifier = body.get("content_id")
            if not isinstance(identifier, str) or self.owned(owner, identifier) is None:
                return error(404, "not_found")
            if action == "hold_next_content":
                self.server.hold_reads.add((owner, f"/v1/contents/{identifier}"))
            else:
                del self.server.contents[identifier]
                self.server.emit(owner, "content", identifier, identifier, "delete")
        else:
            return error(422, "validation_error")
        return 200, {"ok": True}

    def list_contents(self, query):
        owner = self.current_owner()
        if owner is None:
            return error(401, "unauthorized")
        try:
            limit = int(query.get("limit", ["20"])[0])
        except ValueError:
            return error(422, "validation_error")
        if not 1 <= limit <= 100:
            return error(422, "validation_error")

        cursor = query.get("cursor", [None])[0]
        boundary = self.server.cursors.get((owner, cursor))
        if cursor is not None and boundary is None:
            return error(400, "invalid_cursor")

        def order(item):
            return datetime.fromisoformat(item["created_at"].replace("Z", "+00:00")), item["id"]

        items = sorted((item for item in self.server.contents.values() if item["user_id"] == owner),
                       key=order, reverse=True)
        if boundary is not None:
            items = [item for item in items if order(item) < boundary]
        next_cursor = None
        if len(items) > limit:
            next_cursor = str(uuid4())
            self.server.cursors[owner, next_cursor] = order(items[limit - 1])
        page = {"items": deepcopy(items[:limit]), "next_cursor": next_cursor}
        self.server.validators["ContentPage"].validate(page)
        return 200, page

    def content_request(self, path, patch=None):
        owner = self.current_owner()
        if owner is None:
            return error(401, "unauthorized")
        value = self.owned(owner, path.removeprefix("/v1/contents/")) if path.startswith("/v1/contents/") else None
        if value is None:
            return error(404, "not_found")
        if patch is not None:
            if patch["expected_version"] != value["version"]:
                return error(409, "version_conflict", current_version=value["version"])
            for key in ("title", "user_note", "workflow_status"):
                if key in patch:
                    value[key] = patch[key]
            value.update(version=value["version"] + 1, updated_at=utc(time.time()))
            self.server.emit(owner, "content", value["id"], value["id"])
        self.server.validators["Content"].validate(value)
        return 200, deepcopy(value)

    def mock_analysis(self, identifier, body):
        owner = self.current_owner()
        if owner is None:
            return error(401, "unauthorized")
        value = self.owned(owner, identifier)
        if value is None:
            return error(404, "not_found")
        status = body.get("status") if isinstance(body, dict) else None
        if status not in ("pending", "processing", "completed", "partial", "failed"):
            return error(422, "validation_error")
        if value["analysis_status"] != status:
            timestamp = utc(time.time())
            analysis = deepcopy(self.server.analysis_examples.get(status))
            if analysis is not None:
                analysis.update(id=str(uuid4()), content_id=identifier, created_at=timestamp)
            value.update(analysis=analysis, analysis_status=status,
                         version=value["version"] + 1, updated_at=timestamp)
            state = value["notification"]
            if state["visibility"] == "active":
                state.update(revision=state["revision"] + 1, updated_at=timestamp)
                self.server.emit(owner, "notification", identifier, identifier)
            self.server.emit(owner, "content", identifier, identifier)
        self.server.validators["Content"].validate(value)
        return 200, deepcopy(value)

    def token(self, grant, body):
        if self.headers.get("apikey") != PUBLISHABLE_KEY or not isinstance(body, dict):
            return 401, {"error_code": "invalid_credentials"}
        if grant == "password" and body.get("password") == PASSWORD:
            email = body.get("email")
        elif grant == "refresh_token":
            email = self.server.refresh_tokens.pop(body.get("refresh_token"), None)
        else:
            email = None
        if email not in USERS:
            return 400, {"error_code": "invalid_credentials"}
        return 200, self.server.session(email)

    def api(self, path, body):
        server = self.server
        owner = self.current_owner()
        if owner is None:
            return (*error(401, "unauthorized"), False)
        key = self.headers.get("Idempotency-Key", "")
        if not 8 <= len(key) <= 128:
            return (*error(422, "validation_error"), False)
        scope = (owner, path, key)
        if scope in server.receipts:
            original, status, value = server.receipts[scope]
            if original != body:
                return (*error(409, "idempotency_conflict"), False)
            if path == "/v1/assets/uploads" and server.assets[value["asset_id"]]["expires"] <= time.time():
                return (*error(409, "upload_expired"), False)
            print(f"Mock replay {path.rsplit('/', 1)[-1]} {status}", flush=True)
            return status, value, False

        if path == "/v1/assets/uploads":
            status, value = self.reserve(owner, body)
        elif path.startswith("/v1/assets/") and path.endswith("/complete"):
            status, value = self.complete(owner, path.split("/")[-2], body)
        elif path == "/v1/contents":
            status, value = self.create_content(owner, body)
        elif path == "/v1/notification-events":
            status, value = self.change_notice(owner, body)
        elif path.startswith("/v1/contents/") and path.endswith("/notification/restore"):
            restore_id = path.removeprefix("/v1/contents/").removesuffix("/notification/restore")
            status, value = self.change_notice(owner, body, restore_id=restore_id)
        else:
            status, value = error(404, "not_found")

        hold = False
        if status in (200, 201):
            server.receipts[scope] = (body, status, deepcopy(value))
            print(f"Mock commit {path.rsplit('/', 1)[-1]} {status}", flush=True)
            if path == "/v1/contents" and server.hold_text and body.get("source_text") == server.hold_text:
                server.hold_text = None
                hold = True
        return status, value, hold

    def change_notice(self, owner, body, restore_id=None):
        schema = "NotificationRestore" if restore_id is not None else "NotificationEvent"
        if not self.server.validators[schema].is_valid(body):
            return error(422, "validation_error")
        item = self.owned(owner, body["content_id"] if restore_id is None else restore_id)
        if item is None:
            return error(404, "not_found")
        state = item["notification"]
        generation = body["generation"] if restore_id is None else body["expected_generation"]
        target = "dismissed" if restore_id is None else "active"
        if restore_id is None and generation < state["generation"]:
            reason = "stale_generation"
        elif generation != state["generation"] or body["expected_revision"] != state["revision"]:
            return error(409, "notification_conflict", current_generation=state["generation"],
                         current_revision=state["revision"])
        elif state["visibility"] == target:
            reason = f"already_{target}"
        else:
            reason = "applied"
            state.update(visibility=target, generation=generation + int(restore_id is not None),
                         revision=state["revision"] + 1, updated_at=utc(time.time()))
            self.server.emit(owner, "notification", item["id"], item["id"])
        value = {"state": deepcopy(state), "applied": reason == "applied", "reason": reason}
        self.server.validators["NotificationResult"].validate(value)
        return 200, value

    def reserve(self, owner, body):
        server = self.server
        if not server.validators["AssetUploadCreate"].is_valid(body):
            return error(422, "validation_error")
        asset_id, capability = str(uuid4()), str(uuid4())
        expires = int(time.time()) + 7200
        server.assets[asset_id] = {
            "owner": owner, "metadata": body, "capability": capability, "expires": expires,
            "ready": False, "attached": False, "bytes": None,
        }
        host = server.args.device_host
        value = {
            "asset_id": asset_id,
            "upload_url": f"http://{host}:{server.server_port}/mock-storage/{asset_id}?cap={capability}",
            "upload_headers": {"Content-Type": body["media_type"], "x-upsert": "false"},
            "expires_at": utc(expires),
        }
        server.validators["AssetUpload"].validate(value)
        return 201, value

    def do_PUT(self):
        path = urlsplit(self.path)
        try:
            data = self.read_payload(20 * 1024 * 1024)
        except ValueError:
            self.respond(413, {"error": "TooLarge"})
            return
        with self.server.lock:
            asset = self.server.assets.get(path.path.removeprefix("/mock-storage/"))
            cap = parse_qs(path.query).get("cap", [""])[0]
            if asset is None or cap != asset["capability"] or "Authorization" in self.headers:
                result = (403, {"error": "InvalidCapability"})
            elif self.server.expire_next_capability or asset["expires"] <= time.time():
                self.server.expire_next_capability = False
                asset["expires"] = 0
                result = (403, {"error": "ExpiredToken"})
                print("Mock signed capability expired", flush=True)
            elif self.headers.get("x-upsert") != "false" or self.headers.get("Content-Type") != asset["metadata"]["media_type"]:
                result = (422, {"error": "InvalidUploadHeaders"})
            elif asset["bytes"] is not None:
                result = (409, {"error": "Duplicate"})
            else:
                asset["bytes"] = data
                result = (200, {"stored": True})
                print("Mock private bytes stored", flush=True)
        self.respond(*result)

    def complete(self, owner, asset_id, body):
        asset = self.server.assets.get(asset_id)
        if asset is None or asset["owner"] != owner:
            return error(404, "not_found")
        if asset["expires"] <= time.time() and not asset["ready"]:
            return error(409, "upload_expired")
        data, metadata = asset["bytes"], asset["metadata"]
        if (body is not None or not data or len(data) != metadata["size_bytes"]
                or hashlib.sha256(data).hexdigest() != metadata["sha256"]
                or not matches_type(data, metadata["media_type"])):
            return error(422, "validation_error")
        value = {"asset_id": asset_id, "status": "ready", **{key: metadata[key] for key in ("media_type", "size_bytes", "sha256")}}
        self.server.validators["AssetComplete"].validate(value)
        asset["ready"] = True
        return 200, value

    def create_content(self, owner, body):
        server = self.server
        if not server.validators["ContentCreate"].is_valid(body):
            return error(422, "validation_error")
        ids = body.get("asset_ids", [])
        kind = body["input_type"]
        if ((kind == "text" and not (body.get("source_text") or "").strip())
                or (kind == "url" and not body.get("source_url"))
                or (kind in ("image", "document") and not ids) or len(ids) != len(set(ids))):
            return error(422, "validation_error")
        assets = [server.assets.get(str(UUID(asset_id))) for asset_id in ids]
        if any(asset is None or asset["owner"] != owner for asset in assets):
            return error(404, "not_found")
        if any(not asset["ready"] or asset["attached"] for asset in assets):
            return error(409, "asset_unavailable")
        identifier, timestamp = str(uuid4()), utc(int(time.time()))
        value = {
            "id": identifier, "user_id": owner, "input_type": kind,
            "source_text": body.get("source_text"), "source_url": body.get("source_url"), "asset_ids": ids,
            "title": None, "user_note": None, "analysis_status": "pending", "workflow_status": "pending",
            "version": 1, "created_at": timestamp, "updated_at": timestamp, "analysis": None,
            "recommendations": [], "notification": {
                "content_id": identifier, "visibility": "active", "generation": 1, "revision": 1,
                "updated_at": timestamp,
            },
        }
        server.validators["Content"].validate(value)
        for asset in assets:
            asset["attached"] = True
        server.contents[identifier] = deepcopy(value)
        server.emit(owner, "content", identifier, identifier)
        return 201, value


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8782)
    parser.add_argument("--device-host", choices=["10.0.2.2", "127.0.0.1", "localhost"], default="10.0.2.2")
    parser.add_argument("--expire-first-capability", action="store_true")
    parser.add_argument("--hold-source-text", help="Synthetic text for the lost-acknowledgment test")
    parser.add_argument("--seed-catalog", action="store_true", help="Add synthetic catalog items to account A")
    parser.add_argument("--sync-page-size", type=int, choices=range(1, 101), default=100, metavar="1..100")
    parser.add_argument("--replay-sync-prefix", action="store_true", help="Include duplicate sync events in test pages")
    with MockUploadServer(parser.parse_args()) as server:
        print(f"ITDA mock upload server listening on loopback port {server.server_port}", flush=True)
        server.serve_forever()
