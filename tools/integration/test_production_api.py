"""Opt-in HTTP and worker checks using a disposable local Supabase database."""

import asyncio
import hashlib
import os
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from io import BytesIO
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import urlencode
from uuid import uuid4

import httpx
import pytest
import yaml
from jsonschema import Draft202012Validator, FormatChecker
from PIL import Image, ImageDraw, ImageFont
from pydantic import SecretStr
from sqlalchemy import text
from sqlalchemy.engine import make_url
from sqlalchemy.ext.asyncio import async_sessionmaker

from app.config import get_settings
from app.database import create_database_engine
from app.models import MAX_ASSET_BYTES
from app.storage import SupabaseStorage
from common import Auth, account, api_base, base_url, expect, lab_setting, request
from extractors.ai_extractor import ExtractionResult
from smoke import scan_sync
from worker.pipeline import process_pending_jobs, recover_expired_jobs


pytestmark = pytest.mark.skipif(
    os.environ.get("ITDA_TEST_LOCAL_PRODUCTION") != "1",
    reason="Requires the disposable Local lab with real Auth and PostgreSQL",
)


@dataclass(frozen=True)
class LiveApi:
    call: Callable
    base: str
    sessions: dict = field(repr=False)


@pytest.fixture(scope="module")
def api():
    specification = yaml.safe_load(
        (Path(__file__).resolve().parents[2] / "contracts/openapi.yaml").read_text(encoding="utf-8")
    )
    base = api_base("local", os.getenv("ITDA_TEST_LOCAL_API_URL"))
    auth = Auth.from_environment("local")
    if auth_override := os.getenv("ITDA_TEST_LOCAL_AUTH_URL"):
        auth = Auth(base_url(auth_override, allow_local_http=True, local_only=True), auth.key)
    sessions = {label: auth.sign_in(*account(label, "local")) for label in ("A", "B")}
    auth.check_signing_mode(sessions.values(), lab_setting("local", "JWT_ALGORITHM"))
    assert sessions["A"][0] != sessions["B"][0]

    def call(method, route, status=200, *, path=None, owner="A", key=None, body=None, code=None):
        token = sessions[owner][1] if owner in sessions else None
        if owner == "invalid":
            token = "not-a-jwt"
        reply = request(base, path or route, method=method, token=token, body=body, idempotency=key)
        expect(reply, status, code)
        if route in {"/v1/assets/uploads", "/v1/assets/{id}/download-url"} and status < 300:
            assert reply.headers.get("Cache-Control") == "no-store"
        schema = specification["paths"][route][method.lower()]["responses"][str(status)]
        validator = Draft202012Validator(
            {"components": specification["components"], **schema["content"]["application/json"]["schema"]},
            format_checker=FormatChecker(),
        )
        payload = reply.json()
        assert validator.is_valid(payload), f"{method} {route} HTTP {status} deviated from OpenAPI"
        return payload

    return LiveApi(call, base, sessions)


@pytest.fixture
def database_url():
    url = lab_setting("local", "DATABASE_URL")
    parsed = make_url(url)
    assert parsed.host in {"127.0.0.1", "localhost", "::1"} and not {"host", "port"} & parsed.query.keys()
    return SecretStr(url)


def checkpoint(api, owner="A"):
    return scan_sync(api.base, api.sessions[owner][1])[0]


def sync_page(call, cursor, *, owner="A", limit=3, status=200, code=None):
    return call("GET", "/v1/sync", status, path="/v1/sync?" + urlencode({"cursor": cursor, "limit": limit}),
                owner=owner, code=code)


def receipt(call, source, key):
    return call("POST", "/v1/contents", 201, key=key, body={"input_type": "text", "source_text": source})


async def process_one(database_url, content_id, analyze_text=None, **adapters):
    engine = create_database_engine(database_url.get_secret_value())
    sessions = async_sessionmaker(engine)
    try:
        async with sessions() as db:
            queued = await db.scalars(text("SELECT content_id::text FROM public.analysis_jobs WHERE status = 'queued'"))
            assert queued.all() == [content_id], "Use a disposable lab with an empty Worker queue before the audit"
        assert await process_pending_jobs(sessions, "local-audit", analyze_text=analyze_text, **adapters)
        async with sessions() as db:
            row = (await db.execute(text("""
                SELECT status, attempts, locked_by FROM public.analysis_jobs
                WHERE content_id = CAST(:content_id AS uuid)
            """), {"content_id": content_id})).one()
            assert tuple(row) == ("completed", 1, None)
    finally:
        await engine.dispose()


def test_live_routes_and_deterministic_worker(api, database_url):
    call = api.call
    assert call("GET", "/health", owner=None)["persistence"] == "postgresql"
    call("GET", "/v1/contents", 401, owner=None, code="unauthorized")
    call("GET", "/v1/contents", 401, owner="invalid", code="unauthorized")
    call("GET", "/v1/contents", 422, path="/v1/contents?limit=0", code="validation_error")
    call("GET", "/v1/contents", 400, path="/v1/contents?cursor=", code="invalid_cursor")

    before_a, before_b = checkpoint(api), checkpoint(api, "B")
    source, key = f"Submit the synthetic form on Tuesday. Run {uuid4()}", str(uuid4())
    with ThreadPoolExecutor(max_workers=2) as executor:
        one = executor.submit(receipt, call, source, key)
        two = executor.submit(receipt, call, source, key)
        created = one.result()
        assert two.result() == created
    content_id = created["id"]
    detail = "/v1/contents/{id}"
    path = f"/v1/contents/{content_id}"
    assert created["source_text"] == source and created["analysis_status"] == "pending"
    assert call("GET", detail, path=path) == created
    assert call("GET", "/v1/contents", path="/v1/contents?limit=1")["items"][0] == created
    call("GET", detail, 404, path=path, owner="B", code="not_found")
    call("PATCH", detail, 404, path=path, owner="B", body={"expected_version": 1}, code="not_found")

    edited = created
    for index in range(11):
        edit = {"expected_version": edited["version"], "title": f"Synthetic edit {index}"}
        edited = call("PATCH", detail, path=path, body=edit)
        assert edited["source_text"] == source and edited["notification"] == created["notification"]
    assert call("GET", detail, path=path) == edited
    conflict = call("PATCH", detail, 409, path=path, body={"expected_version": 1}, code="version_conflict")
    assert conflict["error"]["current_version"] == edited["version"]

    cursor, events = before_a, []
    for page_number in range(4):
        page = sync_page(call, cursor)
        assert page == sync_page(call, cursor)
        assert page["has_more"] is (page_number < 3)
        events.extend(page["events"])
        cursor = page["next_cursor"]
    sequences = [int(event["sequence"]) for event in events]
    assert len(sequences) == 12 and sequences == list(range(sequences[0], sequences[0] + 12))
    assert all(event["entity_type"] == "content" and event["content_id"] == content_id for event in events)
    assert sync_page(call, cursor) == {"events": [], "has_more": False, "next_cursor": cursor}
    assert checkpoint(api, "B") == before_b
    sync_page(call, cursor, owner="B", status=400, code="invalid_cursor")
    sync_page(call, cursor + "0", status=400, code="invalid_cursor")
    sync_page(call, "", status=400, code="invalid_cursor")

    event = {"content_id": content_id, "event_type": "dismissed", "generation": 1, "expected_revision": 1}
    dismiss_key = str(uuid4())
    with ThreadPoolExecutor(max_workers=2) as executor:
        one = executor.submit(call, "POST", "/v1/notification-events", body=event, key=dismiss_key)
        two = executor.submit(call, "POST", "/v1/notification-events", body=event, key=dismiss_key)
        dismissed = one.result()
        assert two.result() == dismissed
    assert dismissed["applied"] and dismissed["state"]["visibility"] == "dismissed"
    before_worker = checkpoint(api)

    async def deterministic(text_source):
        assert text_source == source
        return SimpleNamespace(
            status="SUCCESS",
            summary="The supplied synthetic form is due Tuesday.",
            recommendations=SimpleNamespace(action=[SimpleNamespace(title="Submit the form", why="Due Tuesday")]),
        )

    asyncio.run(process_one(database_url, content_id, deterministic))
    analyzed = call("GET", detail, path=path)
    assert analyzed["analysis_status"] == "completed" and analyzed["analysis"]["coverage"] == "full_text"
    assert analyzed["analysis"]["summary"] == "The supplied synthetic form is due Tuesday."
    assert analyzed["version"] == edited["version"] + 1
    assert analyzed["title"] == edited["title"] and analyzed["notification"] == dismissed["state"]
    assert len(analyzed["recommendations"]) == 1 and not analyzed["recommendations"][0]["accepted"]
    worker_events = sync_page(call, before_worker)["events"]
    assert [(event["entity_type"], event["content_id"]) for event in worker_events] == [("content", content_id)] * 2

    after_worker = checkpoint(api)
    latest = call("PATCH", detail, path=path, body={"expected_version": analyzed["version"], "title": None})
    assert latest["title"] is None and latest == call("GET", detail, path=path)
    for field in ("analysis", "recommendations", "notification", "asset_ids"):
        assert latest[field] == analyzed[field]

    recommendation = latest["recommendations"][0]
    rec_path = f"/v1/recommendations/{recommendation['id']}"
    rec_body = {"expected_version": recommendation["version"], "accepted": True, "user_text": "My edit"}
    updated = call("PATCH", "/v1/recommendations/{id}", path=rec_path, body=rec_body)
    assert updated["accepted"] and updated["text"] == recommendation["text"] and updated["user_text"] == "My edit"
    call("PATCH", "/v1/recommendations/{id}", 404, path=rec_path, body=rec_body, owner="B", code="not_found")
    feedback = {"content_id": content_id, "recommendation_id": recommendation["id"], "event_type": "corrected"}
    feedback_key = str(uuid4())
    recorded = call("POST", "/v1/feedback", 201, body=feedback, key=feedback_key)
    assert call("POST", "/v1/feedback", 201, body=feedback, key=feedback_key) == recorded
    call("POST", "/v1/feedback", 404, body=feedback, key=feedback_key, owner="B", code="not_found")

    prefs = call("GET", "/v1/preferences")
    new_prefs = call("PATCH", "/v1/preferences", body={"expected_version": prefs["version"], "interests": ["Synthetic"]})
    assert new_prefs == call("GET", "/v1/preferences")
    feed = sync_page(call, after_worker)["events"]
    assert [(event["entity_type"], event["content_id"]) for event in feed] == [
        ("content", content_id), ("recommendation", content_id), ("preferences", None),
    ]

    restore_path = f"{path}/notification/restore"
    restored = call("POST", "/v1/contents/{id}/notification/restore", path=restore_path, key=str(uuid4()),
                    body={"expected_generation": 1, "expected_revision": dismissed["state"]["revision"]})
    assert restored["applied"] and restored["state"]["generation"] == 2
    late = call("POST", "/v1/notification-events", body=event, key=str(uuid4()))
    assert late["reason"] == "stale_generation" and late["state"] == restored["state"]

    call("POST", "/v1/assets/{id}/complete", 404, path=f"/v1/assets/{uuid4()}/complete", key=str(uuid4()),
         code="not_found")
    call("GET", "/v1/assets/{id}/download-url", 404, path=f"/v1/assets/{uuid4()}/download-url", code="not_found")


def test_expired_worker_cannot_overwrite_replacement(api, database_url):
    content = receipt(api.call, f"Synthetic lease recovery {uuid4()}", str(uuid4()))
    content_id = content["id"]

    async def exercise():
        engine = create_database_engine(database_url.get_secret_value())
        sessions = async_sessionmaker(engine)
        started, release = asyncio.Event(), asyncio.Event()

        async def earlier(source):
            assert source == content["source_text"]
            started.set()
            await release.wait()
            return SimpleNamespace(status="SUCCESS", summary="Expired result", recommendations=None)

        async def replacement(source):
            assert source == content["source_text"]
            return SimpleNamespace(status="SUCCESS", summary="Replacement result", recommendations=None)

        expired = asyncio.create_task(process_pending_jobs(sessions, "expired-audit", analyze_text=earlier))
        try:
            await asyncio.wait_for(started.wait(), timeout=10)
            async with sessions.begin() as db:
                params = {"content_id": content_id}
                await db.execute(text("""
                    UPDATE public.analysis_jobs SET locked_at = now() - interval '11 minutes'
                    WHERE content_id = CAST(:content_id AS uuid) AND locked_by = 'expired-audit'
                """), params)
            async with sessions.begin() as db:
                assert await recover_expired_jobs(db) == 1
                await db.execute(text("""
                    UPDATE public.analysis_jobs SET available_at = now() WHERE content_id = CAST(:content_id AS uuid)
                """), params)
            assert await process_pending_jobs(sessions, "replacement-audit", analyze_text=replacement)
            release.set()
            assert not await expired
        finally:
            release.set()
            await expired
            await engine.dispose()

    asyncio.run(exercise())
    final = api.call("GET", "/v1/contents/{id}", path=f"/v1/contents/{content_id}")
    assert final["analysis_status"] == "completed" and final["analysis"]["summary"] == "Replacement result"
    assert final["source_text"] == content["source_text"] and final["recommendations"] == []


def test_worker_failure_keeps_source_and_syncs_terminal_state(api, database_url):
    content = receipt(api.call, f"Synthetic provider failure {uuid4()}", str(uuid4()))
    content_id = content["id"]
    before = checkpoint(api)

    async def exercise():
        engine = create_database_engine(database_url.get_secret_value())
        sessions = async_sessionmaker(engine)

        async def unavailable(source):
            assert source == content["source_text"]
            raise RuntimeError("Synthetic provider failure")

        try:
            for attempt in range(1, 4):
                assert not await process_pending_jobs(sessions, "retry-audit", analyze_text=unavailable)
                async with sessions.begin() as db:
                    params = {"id": content_id}
                    job = (await db.execute(text("""
                        SELECT status, attempts, last_error_code, available_at > now() AS delayed
                        FROM public.analysis_jobs WHERE content_id = CAST(:id AS uuid)
                    """), params)).one()
                    expected = "queued" if attempt < 3 else "failed"
                    assert tuple(job[:3]) == (expected, attempt, "worker_processing_error")
                    if expected == "queued":
                        assert job.delayed
                        await db.execute(text("""
                            UPDATE public.analysis_jobs SET available_at = now()
                            WHERE content_id = CAST(:id AS uuid)
                        """), params)
        finally:
            await engine.dispose()

    asyncio.run(exercise())
    saved = api.call("GET", "/v1/contents/{id}", path=f"/v1/contents/{content_id}")
    assert saved["analysis_status"] == "failed" and saved["analysis"] is None
    assert saved["version"] == content["version"] + 1
    assert saved["source_text"] == content["source_text"] and saved["notification"] == content["notification"]
    page = sync_page(api.call, before, limit=10)
    assert not page["has_more"] and len(page["events"]) == 6
    assert all(event["content_id"] == content_id for event in page["events"])



@pytest.mark.skipif(os.getenv("ITDA_TEST_PUBLIC_URLS") != "1", reason="Requires public outbound HTTPS")
@pytest.mark.parametrize(("url", "expected_status", "coverage"), [
    ("https://example.com/", "completed", "full_text"),
    ("https://httpbingo.org/basic-auth/itda-test/disposable", "partial", "metadata_only"),
    ("http://127.0.0.1/", "partial", "unsupported"),
])
def test_public_url_flow_with_deterministic_model(api, database_url, url, expected_status, coverage):
    created = api.call("POST", "/v1/contents", 201, key=str(uuid4()), body={
        "input_type": "url", "source_url": url, "source_text": "Caption from the original share",
    })
    content_id = created["id"]
    assert created["analysis_status"] == "pending" and created["analysis"] is None
    before = checkpoint(api)
    seen = []

    async def analyze(text_source):
        seen.append(text_source)
        assert expected_status == "completed"
        assert "Example Domain" in text_source and "Caption from" not in text_source
        return ExtractionResult(
            status="SUCCESS", summary="Example Domain is reserved for examples.",
            recommendations={"action": [], "info": [], "material": []},
        )

    asyncio.run(process_one(database_url, content_id, analyze))
    finished = api.call("GET", "/v1/contents/{id}", path=f"/v1/contents/{content_id}")
    assert finished["source_url"] == url and finished["source_text"] == created["source_text"]
    assert finished["analysis_status"] == expected_status and finished["analysis"]["coverage"] == coverage
    assert finished["analysis"]["limitations"]
    assert bool(seen) == bool(finished["analysis"]["summary"]) == (expected_status == "completed")
    assert [event["content_id"] for event in sync_page(api.call, before)["events"]] == [content_id] * 2
    api.call("GET", "/v1/contents/{id}", 404, path=f"/v1/contents/{content_id}", owner="B", code="not_found")


LOCAL_STORAGE = pytest.mark.skipif(
    os.getenv("ITDA_TEST_LOCAL_STORAGE") != "1",
    reason="Requires the disposable Supabase Storage service and server key",
)
UPLOAD = "/v1/assets/uploads"
COMPLETE = "/v1/assets/{id}/complete"
DOWNLOAD = "/v1/assets/{id}/download-url"
DETAIL = "/v1/contents/{id}"


def poster_bytes(image_format):
    with Image.new("RGB", (780, 520), "#fffbea") as poster, BytesIO() as output:
        draw = ImageDraw.Draw(poster)
        draw.text((35, 26), "Campus research assistant recruitment", font=ImageFont.load_default(size=32), fill="#182b23")
        draw.multiline_text((35, 120), (
            "Eligible: currently enrolled students\n"
            "Deadline: 20 November 2026, 17:00 KST\n"
            "Submit a cover letter and an academic transcript.\n"
            "Apply at the Research Office front desk.\n"
            "Resource: Research Office application form"
        ), font=ImageFont.load_default(size=26), fill="#182b23", spacing=14)
        poster.save(output, format=image_format)
        return output.getvalue()


def upload_request(declared_type, data, **overrides):
    return {
        "filename": "campus-recruitment", "media_type": declared_type, "size_bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(), **overrides,
    }


def object_request(method, url, **kwargs):
    settings = get_settings()
    loopback = base_url(settings.supabase_url, allow_local_http=True, local_only=True)
    assert url.startswith(f"{loopback}/storage/v1/")
    try:
        with httpx.Client(timeout=20, follow_redirects=False, trust_env=False) as client:
            return client.request(method, url, **kwargs)
    except httpx.HTTPError:
        pytest.fail("Local Storage request failed", pytrace=False)


def complete_path(asset_id):
    return f"/v1/assets/{asset_id}/complete"


def download_path(asset_id):
    return f"/v1/assets/{asset_id}/download-url"


def verify_and_attach(api, media_type, data):
    upload = upload_request(media_type, data)
    reservation = api.call("POST", UPLOAD, 201, body=upload, key=str(uuid4()))
    reply = object_request("PUT", reservation["upload_url"], headers=reservation["upload_headers"], content=data)
    assert 200 <= reply.status_code < 300
    asset_id = reservation["asset_id"]
    api.call("POST", COMPLETE, path=complete_path(asset_id), key=str(uuid4()))
    return api.call("POST", "/v1/contents", 201, key=str(uuid4()), body={
        "input_type": "image", "asset_ids": [asset_id],
    })


@LOCAL_STORAGE
@pytest.mark.parametrize(("media_type", "image_format", "model_status"), [
    ("image/png", "PNG", "SUCCESS"),
    ("image/jpeg", "JPEG", "SUCCESS"),
    ("image/webp", "WEBP", "PARTIAL_CONTENT"),
])
def test_private_storage_and_deterministic_vision(api, database_url, media_type, image_format, model_status):
    call = api.call
    image = poster_bytes(image_format)
    upload = upload_request(media_type, image)
    key = str(uuid4())
    with ThreadPoolExecutor(max_workers=2) as executor:
        pending = [executor.submit(call, "POST", UPLOAD, 201, body=upload, key=key) for _ in range(2)]
        reservation, replay = (future.result() for future in pending)
    assert reservation["asset_id"] == replay["asset_id"]
    same_capability = reservation["upload_url"] == replay["upload_url"]
    assert same_capability and reservation["expires_at"] == replay["expires_at"]
    assert reservation["upload_headers"] == {"Content-Type": media_type, "x-upsert": "false"}
    call("POST", UPLOAD, 409, body={**upload, "filename": "different"}, key=key, code="idempotency_conflict")

    asset_id = reservation["asset_id"]
    content_request = {"input_type": "image", "asset_ids": [asset_id]}
    completion_key = str(uuid4())
    call("POST", COMPLETE, 409, path=complete_path(asset_id), key=completion_key, code="upload_incomplete")
    call("POST", COMPLETE, 404, path=complete_path(asset_id), key=completion_key, owner="B", code="not_found")
    call("GET", DOWNLOAD, 404, path=download_path(asset_id), code="not_found")
    call("POST", "/v1/contents", 409, key=str(uuid4()), body=content_request, code="asset_unavailable")

    owner_id = api.sessions["A"][0]
    base = get_settings().supabase_url
    storage_path = f"content-assets/{owner_id}/{asset_id}/source"
    direct = f"{base}/storage/v1/object/authenticated/{storage_path}"
    direct_headers = {name: {
        "apikey": lab_setting("local", "PUBLIC_KEY"), "Authorization": f"Bearer {api.sessions[name][1]}",
    } for name in ("A", "B")}

    reply = object_request("PUT", reservation["upload_url"], headers=reservation["upload_headers"], content=image)
    assert 200 <= reply.status_code < 300
    assert object_request("GET", direct, headers=direct_headers["A"]).status_code >= 400
    repeated = object_request(
        "PUT", reservation["upload_url"], headers=reservation["upload_headers"], content=image + b"different",
    )
    assert repeated.status_code in {400, 409}
    with ThreadPoolExecutor(max_workers=2) as executor:
        pending = [
            executor.submit(call, "POST", COMPLETE, path=complete_path(asset_id), key=completion_key)
            for _ in range(2)
        ]
        completed, concurrent = (future.result() for future in pending)
    assert completed == concurrent == {
        "asset_id": asset_id, "status": "ready", "size_bytes": len(image),
        "sha256": upload["sha256"], "media_type": media_type,
    }
    call("POST", COMPLETE, 404, path=complete_path(asset_id), key=completion_key, owner="B", code="not_found")
    call("POST", "/v1/contents", 409, key=str(uuid4()), owner="B", body=content_request, code="asset_unavailable")
    call("GET", DOWNLOAD, 404, path=download_path(asset_id), owner="B", code="not_found")
    assert object_request("GET", direct, headers=direct_headers["A"]).content == image
    assert object_request("GET", direct, headers=direct_headers["B"]).status_code >= 400
    assert object_request("GET", direct).status_code >= 400
    assert object_request("GET", f"{base}/storage/v1/object/public/{storage_path}").status_code >= 400

    download = call("GET", DOWNLOAD, path=download_path(asset_id))
    returned = object_request("GET", download["download_url"])
    assert returned.status_code == 200 and returned.content == image
    content_key = str(uuid4())
    content = call("POST", "/v1/contents", 201, key=content_key, body=content_request)
    assert call("POST", "/v1/contents", 201, key=content_key, body=content_request) == content
    call("POST", "/v1/contents", 409, key=str(uuid4()), body=content_request, code="asset_unavailable")
    content_id = content["id"]
    detail_path = f"/v1/contents/{content_id}"
    edited = call("PATCH", DETAIL, body={"expected_version": 1, "title": "My poster", "user_note": "Keep this"},
                  path=detail_path)
    before, other_before = checkpoint(api), checkpoint(api, "B")

    async def deterministic_model(images):
        assert images == [(media_type, image)]
        return ExtractionResult(
            status=model_status,
            summary="Campus research assistant recruitment closes 20 November 2026, 17:00 KST.",
            recommendations={
                "action": [{"title": "Apply at the Research Office", "why": "Submit a cover letter and transcript."}],
                "info": [{"title": "Eligibility", "why": "For currently enrolled students."}],
                "material": [{"title": "Research Office application form", "why": "Named on the notice."}],
            },
        )

    asyncio.run(process_one(database_url, content_id, analyze_images=deterministic_model))
    result = call("GET", DETAIL, path=detail_path)
    expected = ("completed", "full_text") if model_status == "SUCCESS" else ("partial", "partial_text")
    assert (result["analysis_status"], result["analysis"]["coverage"]) == expected
    assert "20 November 2026" in result["analysis"]["summary"] and result["analysis"]["limitations"]
    assert {item["kind"] for item in result["recommendations"]} == {"action", "information", "resource"}
    assert all(not item["accepted"] and item["source_url"] is None for item in result["recommendations"])
    assert result["version"] == edited["version"] + 1 and result["asset_ids"] == [asset_id]
    assert result["title"] == "My poster" and result["user_note"] == "Keep this"
    assert result["notification"] == content["notification"]
    events = sync_page(call, before)["events"]
    assert [event["content_id"] for event in events] == [content_id] * 2
    assert checkpoint(api, "B") == other_before
    call("GET", DETAIL, 404, path=detail_path, owner="B", code="not_found")


@LOCAL_STORAGE
def test_invalid_bytes_size_and_hash_are_never_attached(api):
    call = api.call
    image = poster_bytes("PNG")
    invalid = b"\x89PNG\r\n\x1a\nincomplete png"
    oversized = upload_request("image/png", image, size_bytes=MAX_ASSET_BYTES + 1)
    call("POST", UPLOAD, 413, body=oversized, key=str(uuid4()), code="asset_too_large")
    for data, metadata, code, status in (
        (invalid, {}, "invalid_media_type", 415),
        (image, {"media_type": "image/jpeg"}, "invalid_media_type", 415),
        (image, {"sha256": "0" * 64}, "asset_checksum_mismatch", 422),
        (image, {"size_bytes": len(image) + 1}, "asset_size_mismatch", 422),
    ):
        reservation = call("POST", UPLOAD, 201, body=upload_request("image/png", data, **metadata), key=str(uuid4()))
        stored = object_request("PUT", reservation["upload_url"], headers=reservation["upload_headers"], content=data)
        assert 200 <= stored.status_code < 300
        asset_id = reservation["asset_id"]
        call("POST", COMPLETE, status, path=complete_path(asset_id), key=str(uuid4()), code=code)
        call("POST", "/v1/contents", 409, key=str(uuid4()), code="asset_unavailable",
             body={"input_type": "image", "asset_ids": [asset_id]})

    reservation = call("POST", UPLOAD, 201, body=upload_request("image/png", image), key=str(uuid4()))
    too_many_bytes = object_request(
        "PUT", reservation["upload_url"], headers=reservation["upload_headers"],
        content=image.ljust(MAX_ASSET_BYTES + 1, b"\0"),
    )
    assert too_many_bytes.status_code in {400, 413}
    if too_many_bytes.status_code == 400:
        # The local Storage version wraps its payload-limit error in HTTP 400.
        assert str(too_many_bytes.json().get("statusCode")) == "413"
    call("POST", COMPLETE, 409, path=complete_path(reservation["asset_id"]),
         key=str(uuid4()), code="upload_incomplete")


@LOCAL_STORAGE
def test_image_failure_keeps_original_and_edits(api, database_url):
    image = poster_bytes("JPEG")
    content = verify_and_attach(api, "image/jpeg", image)
    content_id = content["id"]
    asset_id = content["asset_ids"][0]
    before = checkpoint(api)
    edited = None

    async def fail_after_read(images):
        assert images == [("image/jpeg", image)]
        raise RuntimeError("Deterministic vision failure")

    async def retry():
        nonlocal edited
        engine = create_database_engine(database_url.get_secret_value())
        sessions = async_sessionmaker(engine)
        try:
            for attempt in range(3):
                assert not await process_pending_jobs(sessions, "image-retry", analyze_images=fail_after_read)
                if attempt == 0:
                    edited = api.call("PATCH", DETAIL, path=f"/v1/contents/{content_id}",
                                      body={"expected_version": 1, "user_note": "Reviewed during retry"})
                if attempt < 2:
                    async with sessions.begin() as db:
                        await db.execute(text("""
                            UPDATE public.analysis_jobs SET available_at = now()
                            WHERE content_id = CAST(:id AS uuid)
                        """), {"id": content_id})
        finally:
            await engine.dispose()

    asyncio.run(retry())
    failed = api.call("GET", DETAIL, path=f"/v1/contents/{content_id}")
    assert failed["analysis_status"] == "failed" and failed["analysis"]["coverage"] == "metadata_only"
    assert failed["analysis"]["summary"] is None and failed["analysis"]["limitations"]
    assert failed["version"] == edited["version"] + 1
    assert failed["user_note"] == edited["user_note"] and failed["asset_ids"] == [asset_id]
    assert failed["notification"] == content["notification"] and failed["recommendations"] == []
    capability = api.call("GET", DOWNLOAD, path=download_path(asset_id))
    assert object_request("GET", capability["download_url"]).content == image
    assert len(sync_page(api.call, before, limit=20)["events"]) == 7


@LOCAL_STORAGE
def test_missing_model_reports_partial_and_preserves_verified_image(api, database_url, monkeypatch):
    data = poster_bytes("PNG")
    content = verify_and_attach(api, "image/png", data)
    content_id = content["id"]
    storage = SupabaseStorage(get_settings())
    try:
        with monkeypatch.context() as patch:
            patch.setenv("ITDA_LLM_API_KEY", "")
            get_settings.cache_clear()
            asyncio.run(process_one(database_url, content_id, storage=storage))
    finally:
        get_settings.cache_clear()

    result = api.call("GET", DETAIL, path=f"/v1/contents/{content_id}")
    assert result["analysis_status"] == "partial" and result["analysis"]["coverage"] == "metadata_only"
    assert result["analysis"]["summary"] is None and result["analysis"]["limitations"]
    capability = api.call("GET", DOWNLOAD, path=download_path(content["asset_ids"][0]))
    assert object_request("GET", capability["download_url"]).content == data
