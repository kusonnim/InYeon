"""Disposable, thread-safe fixture adapter. NOT durable storage or a production queue."""
import base64
import hashlib
import hmac
import json
import secrets
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
from threading import RLock
from uuid import UUID, uuid4

from app.errors import ApiError
from app.models import Content, ContentCreate

EXAMPLES = Path(__file__).resolve().parents[3] / "contracts" / "examples"


def now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


class FixtureRepository:
    def __init__(self, seed: bool = True):
        self.lock = RLock()
        self.contents: dict[str, dict] = {}
        self.preferences: dict[str, dict] = {}
        self.feedback: list[dict] = []
        self.jobs: list[dict] = []
        self.events: dict[str, list[dict]] = {}
        self.idempotency: dict[tuple, tuple] = {}
        self.cursor_key = secrets.token_bytes(32)
        if seed:
            for item in json.loads((EXAMPLES / "catalog.json").read_text(encoding="utf-8"))["items"]:
                item = Content.model_validate(item).model_dump(mode="json")
                self.contents[item["id"]] = item
                self.emit(item["user_id"], "content", item["id"])

    def owned(self, user: UUID | str, content_id: UUID | str) -> dict:
        value = self.contents.get(str(content_id))
        if not value or value["user_id"] != str(user):
            raise ApiError(404, "not_found", "Content not found")
        return value

    def emit(self, user, kind, entity_id, content_id=None):
        events = self.events.setdefault(str(user), [])
        events.append({"sequence": str(len(events) + 1), "entity_type": kind,
                       "entity_id": str(entity_id),
                       "content_id": str(content_id or entity_id) if kind != "preferences" else None,
                       "operation": "upsert", "occurred_at": now()})

    def once(self, user, scope, key, payload, action):
        index = (str(user), scope, key)
        digest = hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        with self.lock:
            existing = self.idempotency.get(index)
            if existing:
                if not hmac.compare_digest(existing[0], digest):
                    raise ApiError(409, "idempotency_conflict", "Idempotency key was used with a different payload")
                return deepcopy(existing[1])
            response = action()
            self.idempotency[index] = (digest, deepcopy(response))
            return response

    def create(self, user, value: ContentCreate):
        if value.asset_ids:
            raise ApiError(501, "adapter_not_implemented", "Fixture adapter does not accept real file uploads")
        stamp, identifier = now(), str(uuid4())
        content = {"id": identifier, "user_id": str(user), **value.model_dump(mode="json"),
                   "title": None, "user_note": None, "analysis_status": "pending",
                   "workflow_status": "pending", "version": 1, "created_at": stamp,
                   "updated_at": stamp, "analysis": None, "recommendations": [],
                   "notification": {"content_id": identifier, "visibility": "active", "generation": 1,
                                    "revision": 1, "updated_at": stamp}}
        self.contents[identifier] = content
        # Production must commit the content, notification state, job, sync event and receipt atomically.
        self.jobs.append({"id": str(uuid4()), "user_id": str(user), "content_id": identifier, "status": "queued"})
        self.emit(user, "content", identifier)
        return deepcopy(content)

    def check_version(self, value, expected):
        if value["version"] != expected:
            raise ApiError(409, "version_conflict", "Refresh the resource before retrying your edit",
                           current_version=value["version"])

    def patch_content(self, user, identifier, patch):
        with self.lock:
            value = self.owned(user, identifier)
            self.check_version(value, patch.expected_version)
            value.update(patch.model_dump(mode="json", exclude_unset=True, exclude={"expected_version"}))
            value["version"] += 1
            value["updated_at"] = now()
            self.emit(user, "content", identifier)
            return deepcopy(value)

    def recommendation(self, user, identifier):
        for content in self.contents.values():
            if content["user_id"] == str(user):
                for recommendation in content["recommendations"]:
                    if recommendation["id"] == str(identifier):
                        return content, recommendation
        raise ApiError(404, "not_found", "Recommendation not found")

    def patch_recommendation(self, user, identifier, patch):
        with self.lock:
            content, recommendation = self.recommendation(user, identifier)
            self.check_version(recommendation, patch.expected_version)
            updates = patch.model_dump(mode="json", exclude_unset=True, exclude={"expected_version"})
            recommendation.update(updates)
            recommendation["version"] += 1
            recommendation["updated_at"] = now()
            if "accepted" in updates:
                self.feedback.append({"id": str(uuid4()), "user_id": str(user), "content_id": content["id"],
                                      "recommendation_id": str(identifier), "event_type": "accepted" if patch.accepted else "rejected",
                                      "comment": None, "created_at": now()})
            content["version"] += 1
            content["updated_at"] = now()
            self.emit(user, "recommendation", identifier, content["id"])
            self.emit(user, "content", content["id"])
            return deepcopy(recommendation)

    def add_feedback(self, user, value):
        self.owned(user, value.content_id)
        if value.recommendation_id:
            content, _ = self.recommendation(user, value.recommendation_id)
            if content["id"] != str(value.content_id):
                raise ApiError(422, "invalid_reference", "Recommendation does not belong to the content")
        event = {**value.model_dump(mode="json"), "id": str(uuid4()), "user_id": str(user), "created_at": now()}
        self.feedback.append(event)
        return deepcopy(event)

    def get_preferences(self, user):
        with self.lock:
            stamp = now()
            return deepcopy(self.preferences.setdefault(str(user), {"user_id": str(user), "interests": [],
                            "explicit_preferences": [], "mbti": None, "version": 1,
                            "created_at": stamp, "updated_at": stamp}))

    def patch_preferences(self, user, patch):
        with self.lock:
            self.get_preferences(user)
            value = self.preferences[str(user)]
            self.check_version(value, patch.expected_version)
            value.update(patch.model_dump(mode="json", exclude_unset=True, exclude={"expected_version"}))
            value["version"] += 1
            value["updated_at"] = now()
            self.emit(user, "preferences", user)
            return deepcopy(value)

    def notification_event(self, user, event):
        state = self.owned(user, event.content_id)["notification"]
        if event.generation < state["generation"]:
            return {"state": deepcopy(state), "applied": False, "reason": "stale_generation"}
        self.notification_version(state, event.generation, event.expected_revision)
        if state["visibility"] == "dismissed":
            return {"state": deepcopy(state), "applied": False, "reason": "already_dismissed"}
        state.update(visibility="dismissed", revision=state["revision"] + 1, updated_at=now())
        self.emit(user, "notification", event.content_id)
        return {"state": deepcopy(state), "applied": True, "reason": "applied"}

    def notification_version(self, state, generation, revision):
        if state["generation"] != generation or state["revision"] != revision:
            raise ApiError(409, "notification_conflict", "Refresh notification state before retrying",
                           current_generation=state["generation"], current_revision=state["revision"])

    def restore(self, user, identifier, value):
        state = self.owned(user, identifier)["notification"]
        self.notification_version(state, value.expected_generation, value.expected_revision)
        if state["visibility"] == "active":
            return {"state": deepcopy(state), "applied": False, "reason": "already_active"}
        state.update(visibility="active", generation=state["generation"] + 1,
                     revision=state["revision"] + 1, updated_at=now())
        self.emit(user, "notification", identifier)
        return {"state": deepcopy(state), "applied": True, "reason": "applied"}

    def token(self, user, scope, value):
        body = json.dumps([str(user), scope, value], separators=(",", ":")).encode()
        encoded = base64.urlsafe_b64encode(body).decode().rstrip("=")
        signature = hmac.new(self.cursor_key, encoded.encode(), hashlib.sha256).hexdigest()
        return encoded + "." + signature

    def read_token(self, user, scope, token):
        try:
            encoded, signature = token.split(".")
            expected = hmac.new(self.cursor_key, encoded.encode(), hashlib.sha256).hexdigest()
            if not hmac.compare_digest(signature, expected):
                raise ValueError()
            owner, stored_scope, value = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
            if owner != str(user) or stored_scope != scope:
                raise ValueError()
            return value
        except (ValueError, TypeError, UnicodeDecodeError):
            raise ApiError(400, "invalid_cursor", "Cursor is invalid, expired, or belongs to another account") from None

    def list_contents(self, user, cursor, limit):
        with self.lock:
            items = [value for value in self.contents.values() if value["user_id"] == str(user)]
            items.sort(key=lambda item: (item["created_at"], item["id"]), reverse=True)
            if cursor:
                after = self.read_token(user, "contents", cursor)
                items = [item for item in items if [item["created_at"], item["id"]] < after]
            result = items[:limit]
            next_cursor = self.token(user, "contents", [result[-1]["created_at"], result[-1]["id"]]) if len(items) > limit else None
            return {"items": deepcopy(result), "next_cursor": next_cursor}

    def sync(self, user, cursor, limit):
        with self.lock:
            offset = self.read_token(user, "sync", cursor) if cursor else 0
            events = self.events.get(str(user), [])
            page = events[offset:offset + limit]
            end = offset + len(page)
            return {"events": deepcopy(page), "next_cursor": self.token(user, "sync", end), "has_more": end < len(events)}

    def apply_analysis(self, user, identifier, analysis, recommendations, status):
        """Simulation hook for tests; production worker must use a DB transaction and job lease."""
        with self.lock:
            content = self.owned(user, identifier)
            previous = {item["id"]: item for item in content["recommendations"]}
            generated = deepcopy(recommendations)
            for recommendation in generated:
                prior = previous.get(recommendation["id"])
                recommendation["accepted"] = prior["accepted"] if prior else False
                if prior:
                    recommendation["user_text"] = prior["user_text"]
                    recommendation["version"] = prior["version"]
            content.update(analysis=analysis, recommendations=generated,
                           analysis_status=status, version=content["version"] + 1, updated_at=now())
            # AI is never acceptance; retries preserve explicit edits on existing IDs.
            # Visibility and generation are unchanged, including after dismissal.
            state = content["notification"]
            if state["visibility"] == "active":
                state.update(revision=state["revision"] + 1, updated_at=now())
                self.emit(user, "notification", identifier)
            self.emit(user, "content", identifier)
