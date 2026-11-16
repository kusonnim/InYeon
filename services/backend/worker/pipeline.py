import sys
import asyncio
import logging
import re
from pathlib import Path
from typing import Optional, Any
from dataclasses import dataclass, field

from sqlalchemy import text

CURRENT_DIR = Path(__file__).resolve().parent
BACKEND_DIR = CURRENT_DIR.parent

if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from app.config import get_settings
from app.database import append_sync_event, create_worker_session_factory, lock_owner_sync
from app.models import AnalysisStatus, Coverage
from app.storage import AssetObject, IMAGE_FORMATS, SupabaseStorage
from extractors.ai_extractor import (
    ExtractionResult, HostedAnalysisUnavailable, analyze_content_async, analyze_images_async,
)
from extractors.public_page import PageTemporarilyUnavailable, extract_public_page
from extractors.verified_image import MAX_INLINE_IMAGE_BYTES, prepare_model_image


logger = logging.getLogger(__name__)


# 1. ?먮Ц 異붿텧 寃곌낵 ?곗씠???대옒??
@dataclass
class ExtractedSource:
    """異붿텧???먮Ц怨?遺꾩꽍???꾩슂??硫뷀??곗씠??"""

    text: str = ""
    coverage: str = "full_text"
    references: tuple = field(default_factory=tuple)
    limitations: tuple = field(default_factory=tuple)

    # 湲곗〈 肄붾뱶????명솚?깆쓣 ?꾪븳 ?꾨뱶
    title: str = "?쒕ぉ ?놁쓬"
    content_text: str = ""
    source_url: Optional[str] = None
    raw_text: Optional[str] = None

    def __post_init__(self):
        if not self.text:
            self.text = self.content_text or self.raw_text or ""

        if not self.content_text:
            self.content_text = self.text


class MockRecommendationItem:
    def __init__(self, title: str, why: str):
        self.title = title
        self.why = why


class MockRecommendations:
    def __init__(self):
        self.action = [
            MockRecommendationItem(
                "요약 내용 확인",
                "추출된 핵심 내용 검토",
            )
        ]
        self.info = [
            MockRecommendationItem(
                "愿???먮즺 ?먯깋",
                "추가 참고 정보",
            )
        ]
        self.material = []


class MockAnalysisResult:
    def __init__(self, summary: str = "遺꾩꽍 ?꾨즺 ?붿빟"):
        self.status = "SUCCESS"
        self.summary = summary
        self.recommendations = MockRecommendations()


def analyze(content, extract, summarize, recommend):
    """肄섑뀗痢?異붿텧, 遺꾩꽍, 異붿쿇 寃곌낵瑜?寃利앺븯???숆린???뚯씠?꾨씪??"""

    # 1. ?먮Ц 異붿텧
    extracted = extract.extract(content)

    # 2. ?붿빟 諛?遺꾩꽍
    result = summarize.summarize(content.id, extracted)

    # 3. 遺꾩꽍 寃곌낵??肄섑뀗痢?ID 寃利?
    if result.content_id != content.id:
        raise ValueError("Analysis identity does not match content identity")

    # 4. 異붿텧 寃곌낵? 遺꾩꽍 寃곌낵??coverage 寃利?
    if result.coverage != extracted.coverage:
        raise ValueError("Analysis coverage does not match extracted coverage")

    # 5. 異붿쿇 ?앹꽦
    recommendations = recommend.recommend(
        content.id,
        extracted,
        result,
    )

    # 6. 異붿쿇???먮룞?쇰줈 ?섎씫?섏? ?딆븯?붿? 寃利?
    if any(getattr(item, "accepted", False) is True for item in recommendations):
        raise ValueError("Recommendations are never accepted automatically")

    return result, recommendations

# 2. 遺꾩꽍 ?⑥닔
async def analyze_source_async(source_or_text: Any) -> ExtractionResult:
    """異붿텧???먮Ц ?먮뒗 臾몄옄?댁쓣 遺꾩꽍?쒕떎."""

    if isinstance(source_or_text, ExtractedSource):
        text_content = source_or_text.text

    elif isinstance(source_or_text, str):
        text_content = source_or_text

    else:
        text_content = getattr(
            source_or_text,
            "content_text",
            str(source_or_text),
        )

    return await analyze_content_async(text_content)


async def mock_analyze_content_async(content_text: str):
    """?몃? AI 遺꾩꽍???ъ슜?섏? ?딅뒗 ?뚯뒪?몄슜 ?泥?遺꾩꽍 ?⑥닔."""

    return MockAnalysisResult(
        summary=f"遺꾩꽍 ?꾨즺: {content_text[:100]}..."
    )



async def update_analysis_status(db, user_id, content_id, status):
    await db.execute(
        text("""
            UPDATE public.contents
            SET analysis_status = :status,
                version = version + CASE WHEN :status IN ('completed', 'partial', 'failed') THEN 1 ELSE 0 END,
                updated_at = clock_timestamp()
            WHERE id = :content_id AND user_id = :user_id
        """),
        {"status": status, "content_id": content_id, "user_id": user_id},
    )
    await append_sync_event(db, user_id, "content", content_id)


async def recover_expired_jobs(db) -> int:
    owners = await db.scalars(text("""
        SELECT DISTINCT user_id
        FROM public.analysis_jobs
        WHERE status = 'running' AND locked_at <= now() - interval '10 minutes'
        ORDER BY user_id
    """))
    recovered = 0
    for user_id in owners:
        await lock_owner_sync(db, user_id)
        result = await db.execute(
            text("""
                UPDATE public.analysis_jobs
                SET status = CASE WHEN attempts < 3 THEN 'queued' ELSE 'failed' END,
                    available_at = CASE WHEN attempts < 3
                                        THEN clock_timestamp() + interval '30 seconds' ELSE available_at END,
                    locked_at = NULL,
                    locked_by = NULL,
                    last_error_code = 'worker_lock_expired',
                    updated_at = clock_timestamp()
                WHERE user_id = :user_id AND status = 'running'
                  AND locked_at <= clock_timestamp() - interval '10 minutes'
                RETURNING content_id, status
            """),
            {"user_id": user_id},
        )
        for job in result.mappings():
            status = "pending" if job["status"] == "queued" else "failed"
            await update_analysis_status(db, user_id, job["content_id"], status)
            recovered += 1
    return recovered


async def claim_next_job(db, worker_id):
    user_id = await db.scalar(text("""
        SELECT user_id FROM public.analysis_jobs
        WHERE status = 'queued' AND available_at <= now()
        ORDER BY available_at, id
        LIMIT 1
    """))
    if user_id is None:
        return None

    # All sync writers acquire the owner lock before locking entity rows.
    await lock_owner_sync(db, user_id)
    result = await db.execute(
        text("""
            SELECT j.id, j.content_id, j.user_id, j.attempts, c.input_type, c.source_text, c.source_url
            FROM public.analysis_jobs j
            JOIN public.contents c ON (c.id, c.user_id) = (j.content_id, j.user_id)
            WHERE j.user_id = :user_id AND j.status = 'queued' AND j.available_at <= now()
            ORDER BY j.available_at, j.id
            LIMIT 1
            FOR UPDATE OF j SKIP LOCKED
        """),
        {"user_id": user_id},
    )
    job = result.mappings().first()
    if job is None:
        return None

    await db.execute(
        text("""
            UPDATE public.analysis_jobs
            SET status = 'running', attempts = attempts + 1, locked_at = clock_timestamp(),
                locked_by = :worker_id, updated_at = clock_timestamp()
            WHERE id = :id
        """),
        {"id": job["id"], "worker_id": worker_id},
    )
    await update_analysis_status(db, user_id, job["content_id"], "processing")
    return job


async def finish_job(db, job, worker_id, status, *, error=None):
    await lock_owner_sync(db, job["user_id"])
    result = await db.execute(
        text("""
            UPDATE public.analysis_jobs
            SET status = :status,
                available_at = CASE WHEN :status = 'queued'
                                    THEN clock_timestamp() + interval '30 seconds' ELSE available_at END,
                locked_at = NULL,
                locked_by = NULL,
                last_error_code = :error,
                updated_at = clock_timestamp()
            WHERE id = :id AND status = 'running' AND locked_by = :worker_id
              AND attempts = :attempts AND locked_at > clock_timestamp() - interval '10 minutes'
            RETURNING id
        """),
        {
            "id": job["id"],
            "status": status,
            "error": error,
            "worker_id": worker_id,
            "attempts": job["attempts"] + 1,
        },
    )
    return result.scalar_one_or_none() is not None


async def persist_analysis(db, user_id, content_id, coverage, summary, limitations, recommendations):
    result = await db.execute(
        text("""
            INSERT INTO public.analyses (content_id, user_id, coverage, summary, limitations)
            VALUES (:content_id, :user_id, :coverage, :summary, :limitations)
            ON CONFLICT (content_id) DO NOTHING
            RETURNING id
        """),
        {
            "content_id": content_id,
            "user_id": user_id,
            "coverage": coverage,
            "summary": summary,
            "limitations": limitations,
        },
    )
    analysis_id = result.scalar_one_or_none()
    if analysis_id is None:
        # A published result has existing recommendation identities and user edits.
        return

    for source_category, kind in (("action", "action"), ("info", "information"), ("material", "resource")):
        for item in getattr(recommendations, source_category, []):
            recommendation_text = f"{item.title}: {item.why}".strip(": ")
            if recommendation_text:
                await db.execute(
                    text("""
                        INSERT INTO public.recommendations (content_id, user_id, analysis_id, kind, text)
                        VALUES (:content_id, :user_id, :analysis_id, :kind, :text)
                    """),
                    {
                        "content_id": content_id,
                        "user_id": user_id,
                        "analysis_id": analysis_id,
                        "kind": kind,
                        "text": recommendation_text,
                    },
                )


@dataclass(frozen=True)
class _AnalysisOutcome:
    status: AnalysisStatus
    coverage: Coverage
    limitations: tuple[str, ...] = ()
    summary: str | None = None
    recommendations: Any = None


class _AnalysisAttemptError(Exception):
    def __init__(self, code: str, coverage: Coverage, limitations: tuple[str, ...]):
        super().__init__(code)
        self.code = code
        self.coverage = coverage
        self.limitations = limitations


MODEL_UNAVAILABLE = "현재 분석 서비스를 사용할 수 없습니다. 저장한 원본은 계속 확인할 수 있습니다."
MODEL_FAILED = "재시도 한도 내에 분석 서비스에서 확인 가능한 결과를 받지 못했습니다."
INSUFFICIENT = "분석 가능한 원문 내용이 부족합니다."
WEB_ADDRESS = re.compile(r"""(?i)\b(?:https?://|www\.)[^\s<>"'{}\[\]()]+""")


def _validate_web_addresses(result, allowed_text: str) -> None:
    output = [result.summary]
    for category in ("action", "info", "material"):
        for item in getattr(result.recommendations, category, []):
            output.extend((item.title, item.why))
    allowed_addresses = {address.rstrip(".,;:!?") for address in WEB_ADDRESS.findall(allowed_text)}
    generated_addresses = {
        address.rstrip(".,;:!?") for part in output for address in WEB_ADDRESS.findall(part)
    }
    if not generated_addresses <= allowed_addresses:
        raise ValueError("Analysis contained an unsupported web address")


async def _summarize(
    analyzer, source, input_type, coverage: Coverage, limitations: tuple[str, ...] = (),
) -> _AnalysisOutcome:
    try:
        result = await analyzer(source)
        if result.status == "INSUFFICIENT_CONTENT":
            return _AnalysisOutcome(
                "partial", "metadata_only" if input_type == "image" else coverage,
                (*limitations, INSUFFICIENT),
                result.summary if input_type == "text" else None,
            )
        if result.status not in {"SUCCESS", "PARTIAL_CONTENT"} or not result.summary.strip():
            raise ValueError("Analysis did not return a usable result")
        if input_type == "url":
            _validate_web_addresses(result, source)
        elif input_type == "image":
            _validate_web_addresses(result, "")
        if result.status == "PARTIAL_CONTENT":
            limitations = (*limitations, "원문의 일부만 분석할 수 있었습니다.")
            return _AnalysisOutcome(
                "partial", coverage if input_type == "text" else "partial_text",
                limitations, result.summary, result.recommendations,
            )
        status: AnalysisStatus = "partial" if coverage == "partial_text" else "completed"
        return _AnalysisOutcome(status, coverage, limitations, result.summary, result.recommendations)
    except HostedAnalysisUnavailable:
        if input_type == "image":
            return _AnalysisOutcome("partial", "metadata_only", (MODEL_UNAVAILABLE,))
        return _AnalysisOutcome("partial", coverage, (*limitations, MODEL_UNAVAILABLE))
    except Exception as exc:
        if input_type == "text":
            raise
        raise _AnalysisAttemptError(
            "model_processing_error", "metadata_only" if input_type == "image" else coverage,
            (*limitations, MODEL_FAILED),
        ) from exc


async def _analyze_image_job(session_factory, job, storage, analyzer) -> _AnalysisOutcome:
    async with session_factory() as db:
        result = await db.execute(text("""
            SELECT object_path, media_type, size_bytes, sha256
            FROM public.content_assets
            WHERE content_id = :content_id AND user_id = :user_id
              AND status = 'ready' AND verified_at IS NOT NULL
            ORDER BY created_at, id
        """), {"content_id": job["content_id"], "user_id": job["user_id"]})
        assets = [AssetObject(**row) for row in result.mappings()]

    if not assets or any(asset.media_type not in IMAGE_FORMATS for asset in assets):
        return _AnalysisOutcome("partial", "metadata_only", ("분석 가능한 검증된 이미지가 없습니다.",))

    storage = storage or SupabaseStorage(get_settings())
    if not storage.configured:
        return _AnalysisOutcome("partial", "metadata_only", (
            "현재 비공개 저장소에서 원본 이미지를 읽을 수 없습니다.",
        ))
    if analyzer is None and not get_settings().llm_api_key.get_secret_value():
        return _AnalysisOutcome("partial", "metadata_only", (MODEL_UNAVAILABLE,))

    images = []
    limitations = []
    byte_budget = MAX_INLINE_IMAGE_BYTES // len(assets)
    try:
        for asset in assets:
            data = await storage.read_verified(asset)
            image, notes = await asyncio.to_thread(prepare_model_image, asset.media_type, data, byte_budget)
            images.append(image)
            limitations.extend(notes)
    except Exception as exc:
        raise _AnalysisAttemptError(
            "asset_read_failed", "metadata_only",
            ("재시도 한도 내에 검증된 원본 이미지를 읽을 수 없었습니다.",),
        ) from exc
    coverage: Coverage = "partial_text" if limitations else "full_text"
    return await _summarize(
        analyzer or analyze_images_async, images, "image", coverage,
        ("분석 범위는 이미지에서 읽을 수 있는 텍스트입니다.", *dict.fromkeys(limitations)),
    )


async def _analyze_job(
    session_factory, job, analyze_text, extract_url, storage, analyze_images,
) -> _AnalysisOutcome:
    input_type = job["input_type"]
    if input_type == "text":
        return await _summarize(analyze_text, job["source_text"] or "", input_type, "full_text")
    if input_type == "url":
        try:
            page = await extract_url(job["source_url"])
        except PageTemporarilyUnavailable:
            raise _AnalysisAttemptError(
                "url_fetch_unavailable", "metadata_only",
                ("재시도 한도 내에 공개 페이지에서 본문을 가져올 수 없었습니다.",),
            ) from None
        if not page.text:
            return _AnalysisOutcome("partial", page.coverage, page.limitations)
        return await _summarize(analyze_text, page.text, input_type, page.coverage, page.limitations)
    if input_type == "image":
        return await _analyze_image_job(session_factory, job, storage, analyze_images)
    return _AnalysisOutcome("partial", "unsupported", (f"{input_type} 입력의 원문 추출은 아직 지원하지 않습니다.",))


async def process_pending_jobs(
    session_factory, worker_id: str, *, analyze_text=None, extract_url=extract_public_page,
    storage=None, analyze_images=None,
) -> bool:
    async with session_factory() as db, db.begin():
        await recover_expired_jobs(db)
    async with session_factory() as db, db.begin():
        job = await claim_next_job(db, worker_id)
    if job is None:
        return False

    user_id, content_id = job["user_id"], job["content_id"]
    try:
        outcome = await _analyze_job(
            session_factory, job, analyze_text or analyze_content_async, extract_url, storage, analyze_images,
        )

        async with session_factory() as db, db.begin():
            if not await finish_job(db, job, worker_id, "completed"):
                return False
            await persist_analysis(
                db, user_id, content_id, outcome.coverage, outcome.summary,
                list(outcome.limitations), outcome.recommendations,
            )
            await update_analysis_status(db, user_id, content_id, outcome.status)
        logger.info("Worker analysis completed: content_id=%s", content_id)
        return True
    except Exception as exc:
        logger.warning("Worker processing failed: job_id=%s error_type=%s", job["id"], type(exc).__name__)
        retry = job["attempts"] + 1 < 3
        error = exc.code if isinstance(exc, _AnalysisAttemptError) else "worker_processing_error"
        async with session_factory() as db, db.begin():
            if await finish_job(
                db, job, worker_id, "queued" if retry else "failed", error=error
            ):
                if not retry and isinstance(exc, _AnalysisAttemptError):
                    await persist_analysis(db, user_id, content_id, exc.coverage, None, list(exc.limitations), None)
                await update_analysis_status(db, user_id, content_id, "pending" if retry else "failed")
        return False


async def main():
    from uuid import uuid4

    logger.info("ITDA Worker starting")
    engine, session_factory = create_worker_session_factory()
    worker_id = f"worker-{uuid4()}"
    storage = SupabaseStorage(get_settings())
    try:
        while True:
            if not await process_pending_jobs(session_factory, worker_id, storage=storage):
                await asyncio.sleep(2)
    finally:
        await engine.dispose()
        logger.info("ITDA Worker database engine disposed")


if __name__ == "__main__":
    asyncio.run(main())
