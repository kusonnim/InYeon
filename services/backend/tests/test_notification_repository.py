import asyncio

from app.repository import PostgresRepository


class FakeResult:
    def __init__(self, value):
        self.value = value

    def scalar_one(self):
        return self.value


class FakeSession:
    def __init__(self, response):
        self.response = response
        self.calls = []

    def begin(self):
        return self

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        return False

    async def execute(self, sql, params):
        self.calls.append((str(sql), params))
        return FakeResult(self.response)


def make_repository():
    return PostgresRepository.__new__(PostgresRepository)


def test_notification_event_calls_dismiss_function():
    expected = {"applied": True, "reason": "applied"}
    session = FakeSession(expected)
    repo = make_repository()

    result = asyncio.run(
        repo.notification_event(
            db=session,
            user_id="user-1",
            event_data={
                "content_id": "10000000-0000-4000-8000-000000000001",
                "generation": 1,
                "expected_revision": 2,
            },
        )
    )

    assert result == expected
    assert len(session.calls) == 1
    assert "dismiss_notification" in session.calls[0][0]
    assert session.calls[0][1]["generation"] == 1


def test_restore_notification_calls_restore_function():
    expected = {"applied": True, "reason": "applied"}
    session = FakeSession(expected)
    repo = make_repository()

    result = asyncio.run(
        repo.restore_notification(
            db=session,
            user_id="user-1",
            content_id="10000000-0000-4000-8000-000000000001",
            restore_data={
                "expected_generation": 1,
                "expected_revision": 2,
            },
        )
    )

    assert result == expected
    assert len(session.calls) == 1
    assert "restore_notification" in session.calls[0][0]
    assert session.calls[0][1]["expected_generation"] == 1

import pytest
from types import SimpleNamespace
from sqlalchemy.exc import DBAPIError
from app.errors import ApiError


def test_idempotency_replay_returns_saved_response(monkeypatch):
    expected = {"applied": True, "reason": "applied"}
    session = FakeSession({"should_not": "execute"})
    repo = make_repository()

    async def fake_get_idempotency(**kwargs):
        return {"request_hash": __import__("hashlib").sha256(
            b'{"content_id":"c1","expected_revision":2,"generation":1}'
        ).hexdigest(), "response_body": expected}

    monkeypatch.setattr(repo, "get_idempotency", fake_get_idempotency)

    result = asyncio.run(
        repo.notification_event(
            db=session,
            user_id="user-1",
            idempotency_key="same-key",
            event_data={
                "content_id": "c1",
                "generation": 1,
                "expected_revision": 2,
            },
        )
    )

    assert result == expected
    assert len(session.calls) == 1 and "lock_sync_head" in session.calls[0][0]


def test_idempotency_key_with_different_request_conflicts(monkeypatch):
    session = FakeSession({})
    repo = make_repository()

    async def fake_get_idempotency(**kwargs):
        return {"request_hash": "different-hash", "response_body": {}}

    monkeypatch.setattr(repo, "get_idempotency", fake_get_idempotency)

    with pytest.raises(ApiError) as exc:
        asyncio.run(
            repo.notification_event(
                db=session,
                user_id="user-1",
                idempotency_key="same-key",
                event_data={
                    "content_id": "c1",
                    "generation": 1,
                    "expected_revision": 2,
                },
            )
        )

    assert exc.value.status == 409
    assert exc.value.body["error"]["code"] == "idempotency_conflict"
    assert len(session.calls) == 1 and "lock_sync_head" in session.calls[0][0]


def test_postgres_notification_conflict_maps_to_api_error():
    class ErrorSession(FakeSession):
        async def execute(self, sql, params):
            original = SimpleNamespace(sqlstate="P0001")
            raise DBAPIError(str(sql), params, original)

    repo = make_repository()

    with pytest.raises(ApiError) as exc:
        asyncio.run(
            repo.notification_event(
                db=ErrorSession(None),
                user_id="user-1",
                event_data={
                    "content_id": "c1",
                    "generation": 1,
                    "expected_revision": 2,
                },
            )
        )

    assert exc.value.status == 409
    assert exc.value.body["error"]["code"] == "notification_conflict"
