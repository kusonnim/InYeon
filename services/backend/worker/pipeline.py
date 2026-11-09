"""Stage boundaries for Developer B. No network fetching, LLM, or task loop is implemented."""
from dataclasses import dataclass
from typing import Protocol
from uuid import UUID

from app.models import Analysis, Content, Coverage, Recommendation


@dataclass(frozen=True)
class ExtractedSource:
    text: str
    coverage: Coverage
    references: tuple[str, ...]
    limitations: tuple[str, ...]


class Extractor(Protocol):
    def extract(self, content: Content) -> ExtractedSource: ...


class Summarizer(Protocol):
    def summarize(self, content_id: UUID, source: ExtractedSource) -> Analysis: ...


class Recommender(Protocol):
    def recommend(self, content_id: UUID, source: ExtractedSource, analysis: Analysis) -> list[Recommendation]: ...


class AnalysisPersistence(Protocol):
    def commit_result(self, job_id: UUID, analysis: Analysis, recommendations: list[Recommendation]) -> None: ...


def analyze(content: Content, extractor: Extractor, summarizer: Summarizer,
            recommender: Recommender) -> tuple[Analysis, list[Recommendation]]:
    source = extractor.extract(content)
    analysis = summarizer.summarize(content.id, source)
    recommendations = recommender.recommend(content.id, source, analysis)
    if analysis.content_id != content.id or analysis.coverage != source.coverage:
        raise ValueError("Analysis must retain content identity and accessible source coverage")
    if any(item.content_id != content.id or item.accepted for item in recommendations):
        raise ValueError("Generated recommendations must belong to content and are never accepted automatically")
    return analysis, recommendations
