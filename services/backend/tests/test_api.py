from concurrent.futures import ThreadPoolExecutor
from uuid import UUID

from fastapi.testclient import TestClient
import pytest

from app.config import Settings
from app.main import create_app
from app.models import ContentCreate

ID = "10000000-0000-4000-8000-000000000001"
USER = UUID("00000000-0000-4000-8000-000000000001")


def keyed(auth, key="operation-0001"):
    return {**auth, "Idempotency-Key": key}


def test_production_fails_closed_and_health_is_not_readiness():
    with TestClient(create_app(Settings(mode="production", environment="test"))) as client:
        assert client.get("/health").json()["persistence"] == "unconfigured"
        assert client.get("/v1/contents").status_code == 401
        assert client.get("/v1/contents", headers={"Authorization": "Bearer forged-jwt"}).status_code == 501
    with pytest.raises(ValueError):
        Settings(mode="fixture", environment="production")


def test_atomic_ingestion_idempotent_retry_and_async_job(client, auth):
    body = {"input_type": "text", "source_text": "Remember this source."}
    first = client.post("/v1/contents", json=body, headers=keyed(auth))
    second = client.post("/v1/contents", json=body, headers=keyed(auth))
    assert first.status_code == second.status_code == 201
    assert first.json() == second.json()
    assert first.json()["analysis_status"] == "pending"
    assert first.json()["analysis"] is None
    assert len(client.app.state.repository.jobs) == 1
    assert client.app.state.repository.jobs[0]["status"] == "queued"
    assert client.post("/v1/contents", json={**body, "source_text": "Changed"}, headers=keyed(auth)).json()["error"]["code"] == "idempotency_conflict"


def test_concurrent_duplicate_ingestion_uses_one_job(client):
    repository = client.app.state.repository
    body = ContentCreate(input_type="text", source_text="Concurrent")
    def create(_):
        return repository.once(USER, "create-content", "same-concurrent-key", body.model_dump(mode="json"), lambda: repository.create(USER, body))
    with ThreadPoolExecutor(max_workers=8) as executor:
        results = list(executor.map(create, range(20)))
    assert len({result["id"] for result in results}) == 1
    assert len(repository.jobs) == 1


def test_owner_isolation_and_owner_scoped_idempotency(client, auth):
    other = {"Authorization": "Bearer fixture-user-b"}
    assert client.get(f"/v1/contents/{ID}", headers=other).status_code == 404
    assert client.get("/v1/contents", headers=other).json()["items"] == []
    assert client.patch(f"/v1/contents/{ID}", headers=other, json={"expected_version": 2, "title": "steal"}).status_code == 404
    body = {"input_type": "text", "source_text": "Shared same input"}
    one = client.post("/v1/contents", headers=keyed(auth), json=body).json()
    two = client.post("/v1/contents", headers=keyed(other), json=body).json()
    assert one["id"] != two["id"]
    assert client.post("/v1/feedback", headers=keyed(other, "feedback-key-1"), json={"content_id": ID, "event_type": "accepted"}).status_code == 404


def test_version_conflict_and_source_immutability(client, auth):
    response = client.patch(f"/v1/contents/{ID}", headers=auth, json={"expected_version": 2, "user_note": "My own note", "workflow_status": "completed"})
    assert response.status_code == 200
    value = response.json()
    assert value["version"] == 3 and value["notification"]["visibility"] == "active"
    conflict = client.patch(f"/v1/contents/{ID}", headers=auth, json={"expected_version": 2, "title": "Stale"})
    assert conflict.status_code == 409 and conflict.json()["error"]["current_version"] == 3
    assert client.patch(f"/v1/contents/{ID}", headers=auth, json={"expected_version": 3, "source_text": "Invented"}).status_code == 422


def test_notification_dismissal_analysis_restore_and_delayed_event(client, auth):
    repository = client.app.state.repository
    body = {"content_id": ID, "event_type": "dismissed", "generation": 1, "expected_revision": 2}
    response = client.post("/v1/notification-events", headers=keyed(auth, "dismissal-key-1"), json=body)
    assert response.status_code == 200 and response.json()["state"]["visibility"] == "dismissed"
    content = repository.owned(USER, ID)
    original_source = content["source_text"]
    repository.apply_analysis(USER, ID, content["analysis"], content["recommendations"], "completed")
    assert content["notification"]["visibility"] == "dismissed"
    assert content["notification"]["revision"] == 3
    assert content["workflow_status"] == "pending"
    repository.apply_analysis(USER, ID, None, [], "failed")
    assert content["source_text"] == original_source
    assert content["notification"]["visibility"] == "dismissed"
    restored = client.post(f"/v1/contents/{ID}/notification/restore", headers=keyed(auth, "restore-key-1"), json={"expected_generation": 1, "expected_revision": 3})
    assert restored.json()["state"]["generation"] == 2
    replay = client.post(f"/v1/contents/{ID}/notification/restore", headers=keyed(auth, "restore-key-1"), json={"expected_generation": 1, "expected_revision": 3})
    assert replay.json() == restored.json()
    late = client.post("/v1/notification-events", headers=keyed(auth, "late-event-key-1"), json=body)
    assert late.status_code == 200
    assert late.json()["reason"] == "stale_generation" and not late.json()["applied"]
    assert late.json()["state"]["visibility"] == "active"
    body.update(generation=2, expected_revision=3)
    assert client.post("/v1/notification-events", headers=keyed(auth, "bad-revision-key"), json=body).status_code == 409


def test_generated_is_not_accepted_and_user_edits_are_separate(client, auth):
    content = client.get(f"/v1/contents/{ID}", headers=auth).json()
    recommendation = content["recommendations"][0]
    assert recommendation["accepted"] is False
    response = client.patch(f'/v1/recommendations/{recommendation["id"]}', headers=auth,
                            json={"expected_version": 1, "accepted": True, "user_text": "My revised next step"})
    assert response.status_code == 200
    assert response.json()["text"] == recommendation["text"]
    assert response.json()["user_text"] == "My revised next step"
    assert client.app.state.repository.feedback[-1]["event_type"] == "accepted"
    repository = client.app.state.repository
    repository.apply_analysis(USER, ID, content["analysis"], content["recommendations"], "completed")
    preserved = repository.owned(USER, ID)["recommendations"][0]
    assert preserved["accepted"] is True and preserved["user_text"] == "My revised next step"


def test_zero_recommendations_and_metadata_only_are_valid(client, auth):
    items = client.get("/v1/contents", headers=auth).json()["items"]
    reflection = next(item for item in items if item["id"].endswith("003"))
    inaccessible = next(item for item in items if item["id"].endswith("004"))
    assert reflection["recommendations"] == []
    assert inaccessible["analysis"]["coverage"] == "metadata_only"
    assert inaccessible["analysis"]["summary"] is None


def test_pagination_and_sync_cursors_are_account_bound(client, auth):
    first = client.get("/v1/contents?limit=2", headers=auth).json()
    second = client.get("/v1/contents", params={"cursor": first["next_cursor"], "limit": 2}, headers=auth).json()
    assert not ({item["id"] for item in first["items"]} & {item["id"] for item in second["items"]})
    other = {"Authorization": "Bearer fixture-user-b"}
    assert client.get("/v1/contents", params={"cursor": first["next_cursor"]}, headers=other).status_code == 400
    page = client.get("/v1/sync?limit=100", headers=auth).json()
    assert not page["has_more"]
    client.patch(f"/v1/contents/{ID}", headers=auth, json={"expected_version": 2, "title": "Synced"})
    changes = client.get("/v1/sync", params={"cursor": page["next_cursor"]}, headers=auth).json()
    assert changes["events"][0]["entity_id"] == ID
    assert changes["events"][0]["content_id"] == ID
    assert client.get("/v1/sync", params={"cursor": page["next_cursor"]}, headers=other).status_code == 400


def test_validation_and_uploads_are_honest(client, auth):
    assert client.post("/v1/contents", headers=keyed(auth), json={"input_type": "text", "source_text": " "}).status_code == 422
    assert client.post("/v1/contents", headers=keyed(auth), json={"input_type": "image"}).status_code == 422
    assert client.post("/v1/assets/uploads", headers=keyed(auth), json={"filename": "a.pdf", "media_type": "application/pdf", "size_bytes": 10, "sha256": "a" * 64}).status_code == 501
    assert client.patch(f"/v1/contents/{ID}", headers=auth, json={"expected_version": 2, "workflow_status": None}).status_code == 422
    assert client.get("/v1/contents", headers={"Authorization": "Bearer invalid"}).status_code == 401
