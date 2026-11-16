import asyncio
from types import SimpleNamespace

import pytest

from app.models import Content
from worker.pipeline import ExtractedSource, analyze, recover_expired_jobs


def test_worker_allows_zero_recommendations_and_preserves_coverage(client):
    content = Content.model_validate(next(iter(client.app.state.repository.contents.values())))
    source = ExtractedSource(text="Only an excerpt", coverage="partial_text", references=(), limitations=("Excerpt only",))
    analysis = content.analysis.model_copy(update={"coverage": "partial_text"})
    extract = SimpleNamespace(extract=lambda _: source)
    summarize = SimpleNamespace(summarize=lambda identifier, extracted: analysis)
    recommend = SimpleNamespace(recommend=lambda identifier, extracted, summary: [])
    result, recommendations = analyze(content, extract, summarize, recommend)
    assert result.coverage == "partial_text" and recommendations == []
    summarize.summarize = lambda identifier, extracted: analysis.model_copy(update={"coverage": "full_text"})
    with pytest.raises(ValueError, match="coverage"):
        analyze(content, extract, summarize, recommend)


def test_worker_rejects_automatic_acceptance_and_wrong_identity(client):
    content = Content.model_validate(next(iter(client.app.state.repository.contents.values())))
    source = ExtractedSource(text=content.source_text, coverage="full_text", references=(), limitations=())
    extract = SimpleNamespace(extract=lambda _: source)
    summarize = SimpleNamespace(summarize=lambda identifier, extracted: content.analysis)
    recommend = SimpleNamespace(recommend=lambda identifier, extracted, summary: [content.recommendations[0].model_copy(update={"accepted": True})])
    with pytest.raises(ValueError, match="never accepted"):
        analyze(content, extract, summarize, recommend)
    recommend.recommend = lambda identifier, extracted, summary: []
    summarize.summarize = lambda identifier, extracted: content.analysis.model_copy(update={"content_id": content.user_id})
    with pytest.raises(ValueError, match="identity"):
        analyze(content, extract, summarize, recommend)


@pytest.mark.parametrize(
    ("job_status", "expected_content_status"),
    [
        ("queued", "pending"),
        ("failed", "failed"),
    ],
)
def test_recover_expired_jobs_updates_content_and_sync(
    job_status,
    expected_content_status,
):
    content_id = "test-content-id"
    user_id = "test-user-id"

    expired_jobs = [
        {
            "content_id": content_id,
            "user_id": user_id,
            "status": job_status,
        }
    ]

    class FakeResult:
        def mappings(self):
            return self

        def all(self):
            return expired_jobs

    class FakeDB:
        def __init__(self):
            self.calls = []

        async def execute(self, statement, params=None):
            self.calls.append((str(statement), params))
            if len(self.calls) == 1:
                return FakeResult()
            return None

    db = FakeDB()

    recovered_count = asyncio.run(recover_expired_jobs(db))

    assert recovered_count == 1
    assert len(db.calls) == 3

    recovery_sql = db.calls[0][0]
    assert "attempts < 3" in recovery_sql
    assert "locked_at <= now() - interval '10 minutes'" in recovery_sql

    content_sql, content_params = db.calls[1]
    assert "UPDATE contents" in content_sql
    assert content_params == {
        "status": expected_content_status,
        "content_id": content_id,
    }

    sync_sql, sync_params = db.calls[2]
    assert "append_sync_event" in sync_sql
    assert sync_params == {
        "user_id": user_id,
        "content_id": content_id,
    }



def test_process_pending_jobs_returns_false_when_no_job():
    from worker.pipeline import process_pending_jobs

    class FakeResult:
        def mappings(self):
            return self

        def first(self):
            return None

        def all(self):
            return []

    class FakeDB:
        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        def begin(self):
            return self

        async def execute(self, statement, params=None):
            return FakeResult()

    class FakeSessionFactory:
        def __call__(self):
            return FakeDB()

    result = asyncio.run(
        process_pending_jobs(FakeSessionFactory(), "test-worker")
    )

    assert result is False
