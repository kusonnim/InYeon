from types import SimpleNamespace

import pytest

from app.models import Content
from worker.pipeline import ExtractedSource, analyze


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
