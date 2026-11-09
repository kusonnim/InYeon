"""Loopback-only contract test server for the Android outbox. Use synthetic data."""

import argparse
import base64
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


def error(status, code):
    return status, {"error": {"code": code, "message": "Synthetic test response", "request_id": str(uuid4())}}


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
        self.receipts = {}
        self.expire_next_capability = args.expire_first_capability
        self.hold_text = args.hold_source_text
        document = yaml.safe_load(OPENAPI.read_text(encoding="utf-8"))
        self.validators = {
            name: Draft202012Validator(
                {"$ref": f"#/components/schemas/{name}", "components": document["components"]},
                format_checker=FormatChecker(),
            )
            for name in ("ContentCreate", "Content", "AssetUploadCreate", "AssetUpload", "AssetComplete", "ErrorResponse")
        }

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

    def do_POST(self):
        path = urlsplit(self.path)
        try:
            payload = self.read_payload(1024 * 1024)
            body = json.loads(payload) if payload else None
        except ValueError:
            self.respond(*error(422, "validation_error"))
            return
        with self.server.lock:
            if path.path == "/auth/v1/token":
                status, value = self.token(parse_qs(path.query).get("grant_type", [""])[0], body)
                hold = False
            else:
                status, value, hold = self.api(path.path, body)
        if hold:
            print("Mock content committed. First acknowledgment is delayed.", flush=True)
            time.sleep(75)
        self.respond(status, value)

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
        auth = self.headers.get("Authorization", "")
        session = server.tokens.get(auth.removeprefix("Bearer ")) if auth.startswith("Bearer ") else None
        if session is None or session[1] <= time.time():
            return (*error(401, "unauthorized"), False)
        owner = session[0]
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
        else:
            status, value = error(404, "not_found")

        hold = False
        if status in (200, 201):
            server.receipts[scope] = (body, status, value)
            print(f"Mock commit {path.rsplit('/', 1)[-1]} {status}", flush=True)
            if path == "/v1/contents" and server.hold_text and body.get("source_text") == server.hold_text:
                server.hold_text = None
                hold = True
        return status, value, hold

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
        return 201, value


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8782)
    parser.add_argument("--device-host", choices=["10.0.2.2", "127.0.0.1", "localhost"], default="10.0.2.2")
    parser.add_argument("--expire-first-capability", action="store_true")
    parser.add_argument("--hold-source-text", help="Synthetic text for the lost-acknowledgment test")
    with MockUploadServer(parser.parse_args()) as server:
        print(f"ITDA mock upload server listening on loopback port {server.server_port}", flush=True)
        server.serve_forever()
