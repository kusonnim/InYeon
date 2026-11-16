import sys
import asyncio
import logging
from pathlib import Path
from typing import Optional, Any
from dataclasses import dataclass, field

from sqlalchemy import text

CURRENT_DIR = Path(__file__).resolve().parent
BACKEND_DIR = CURRENT_DIR.parent

if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from app.database import create_worker_session_factory


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
async def analyze_source_async(source_or_text: Any) -> MockAnalysisResult:
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

    try:
        from extractors.ai_extractor import analyze_content_async

        return await analyze_content_async(text_content)

    except Exception:
        return MockAnalysisResult(
            summary=f"遺꾩꽍 ?꾨즺: {text_content[:100]}..."
        )


async def mock_analyze_content_async(content_text: str):
    """?몃? AI 遺꾩꽍???ъ슜?섏? ?딅뒗 ?뚯뒪?몄슜 ?泥?遺꾩꽍 ?⑥닔."""

    return MockAnalysisResult(
        summary=f"遺꾩꽍 ?꾨즺: {content_text[:100]}..."
    )



async def recover_expired_jobs(db) -> int:
    """10분 이상 잠긴 작업을 재시도하거나 최종 실패 처리한다."""
    recovery_result = await db.execute(
        text("""
            UPDATE analysis_jobs
            SET status = CASE
                    WHEN attempts < 3 THEN 'queued'
                    ELSE 'failed'
                END,
                available_at = CASE
                    WHEN attempts < 3 THEN now() + interval '30 seconds'
                    ELSE available_at
                END,
                locked_at = NULL,
                locked_by = NULL,
                last_error_code = 'worker_lock_expired',
                updated_at = now()
            WHERE status = 'running'
              AND locked_at <= now() - interval '10 minutes'
            RETURNING content_id, user_id, status
        """)
    )

    expired_jobs = recovery_result.mappings().all()

    for expired_job in expired_jobs:
        recovered_status = (
            "pending"
            if expired_job["status"] == "queued"
            else "failed"
        )

        await db.execute(
            text("""
                UPDATE contents
                SET analysis_status = :status,
                    updated_at = now()
                WHERE id = :content_id
            """),
            {
                "status": recovered_status,
                "content_id": expired_job["content_id"],
            },
        )

        await db.execute(
            text("""
                SELECT public.append_sync_event(
                    :user_id,
                    'content',
                    :content_id,
                    'upsert',
                    :content_id
                )
            """),
            {
                "user_id": expired_job["user_id"],
                "content_id": expired_job["content_id"],
            },
        )

    return len(expired_jobs)


# 3. PostgreSQL 기반 analysis_jobs 처리 Worker
async def process_pending_jobs(session_factory, worker_id: str) -> bool:
    import uuid

    # 1. 작업 선점: 트랜잭션 안에서 잠금과 상태 변경
    async with session_factory() as db:
        async with db.begin():
            await recover_expired_jobs(db)
            result = await db.execute(
                text("""
                    SELECT
                        j.id,
                        j.content_id,
                        j.user_id,
                        j.attempts,
                        c.input_type,
                        c.source_text,
                        c.source_url
                    FROM analysis_jobs j
                    JOIN contents c ON c.id = j.content_id
                    WHERE j.status = 'queued'
                      AND j.available_at <= now()
                    ORDER BY j.available_at, j.id
                    LIMIT 1
                    FOR UPDATE OF j SKIP LOCKED
                """)
            )

            job = result.mappings().first()

            if job is None:
                return False

            job_id = job["id"]
            content_id = job["content_id"]
            user_id = job["user_id"]
            attempts = job["attempts"] + 1

            await db.execute(
                text("""
                    UPDATE analysis_jobs
                    SET status = 'running',
                        attempts = :attempts,
                        locked_at = now(),
                        locked_by = :worker_id,
                        updated_at = now()
                    WHERE id = :id
                """),
                {
                    "id": job_id,
                    "attempts": attempts,
                    "worker_id": worker_id,
                },
            )

            await db.execute(
                text("""
                    UPDATE contents
                    SET analysis_status = 'processing',
                        updated_at = now()
                    WHERE id = :id
                """),
                {"id": content_id},
            )

    try:
        # 2. 입력 유형별 처리
        input_type = job["input_type"]
        source_text = job["source_text"] or ""

        if input_type != "text":
            coverage = "unsupported"
            summary = (
                "현재 입력 유형은 자동 분석을 지원하지 않습니다. "
                "텍스트 추출 기능이 구현된 후 다시 분석할 수 있습니다."
            )
            limitations = [
                f"{input_type} 입력 추출기가 아직 구현되지 않았습니다."
            ]
            recommendations = MockRecommendations()
            analysis_status = "partial"

        else:
            from extractors.ai_extractor import analyze_content_async

            ai_result = await analyze_content_async(source_text)

            result_status = getattr(ai_result, "status", "ERROR")

            if result_status == "ERROR":
                raise RuntimeError("AI analysis returned ERROR")

            coverage = "full_text"
            summary = ai_result.summary
            limitations = []
            recommendations = ai_result.recommendations

            if result_status == "SUCCESS":
                analysis_status = "completed"
                limitations = []

            elif result_status == "INSUFFICIENT_CONTENT":
                analysis_status = "partial"
                limitations = ["분석 가능한 원문 내용이 부족합니다."]

            else:
                raise RuntimeError(
                    f"Unexpected AI analysis status: {result_status}"
                )
        # 3. 분석 결과와 추천을 하나의 트랜잭션으로 저장
        async with session_factory() as db:
            async with db.begin():

                analysis_result = await db.execute(
                    text("""
                        INSERT INTO analyses (
                            content_id,
                            user_id,
                            coverage,
                            summary,
                            limitations
                        )
                        VALUES (
                            :content_id,
                            :user_id,
                            :coverage,
                            :summary,
                            :limitations
                        )
                        ON CONFLICT (content_id)
                        DO UPDATE SET
                            coverage = EXCLUDED.coverage,
                            summary = EXCLUDED.summary,
                            limitations = EXCLUDED.limitations
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

                analysis_id = analysis_result.scalar_one()

                # 재시도 시 기존 추천 중복 방지
                await db.execute(
                    text("""
                        DELETE FROM recommendations
                        WHERE content_id = :content_id
                    """),
                    {"content_id": content_id},
                )

                category_mapping = [
                    ("action", "action"),
                    ("info", "information"),
                    ("material", "resource"),
                ]

                for source_category, db_kind in category_mapping:
                    items = getattr(
                        recommendations,
                        source_category,
                        [],
                    )

                    for item in items:
                        title = getattr(item, "title", "") or ""
                        why = getattr(item, "why", "") or ""
                        recommendation_text = (
                            f"{title}: {why}".strip(": ")
                        )

                        if not recommendation_text.strip():
                            continue

                        await db.execute(
                            text("""
                                INSERT INTO recommendations (
                                    content_id,
                                    user_id,
                                    analysis_id,
                                    kind,
                                    text
                                )
                                VALUES (
                                    :content_id,
                                    :user_id,
                                    :analysis_id,
                                    :kind,
                                    :text
                                )
                            """),
                            {
                                "content_id": content_id,
                                "user_id": user_id,
                                "analysis_id": analysis_id,
                                "kind": db_kind,
                                "text": recommendation_text,
                            },
                        )

                await db.execute(
                    text("""
                        UPDATE contents
                        SET analysis_status = :status,
                            updated_at = now()
                        WHERE id = :id
                    """),
                    {
                        "id": content_id,
                        "status": analysis_status,
                    },
                )

                await db.execute(
                    text("""
                        UPDATE analysis_jobs
                        SET status = 'completed',
                            locked_at = NULL,
                            locked_by = NULL,
                            last_error_code = NULL,
                            updated_at = now()
                        WHERE id = :id
                    """),
                    {"id": job_id},
                )

                await db.execute(
                    text("""
                        SELECT public.append_sync_event(
                            :user_id,
                            'content',
                            :content_id,
                            'upsert',
                            :content_id
                        )
                    """),
                    {
                        "user_id": user_id,
                        "content_id": content_id,
                    },
                )

        logger.info(
            "Worker analysis completed: content_id=%s",
            content_id,
        )
        return True

    except Exception as e:
        logger.error(
            "Worker processing failed: job_id=%s error=%s",
            job_id,
            str(e),
            exc_info=True,
        )

        # 최대 3회 시도. 재시도 간격은 30초.
        retry = attempts < 3

        async with session_factory() as db:
            async with db.begin():
                await db.execute(
                    text("""
                        UPDATE analysis_jobs
                        SET status = :status,
                            available_at = CASE
                                WHEN :retry THEN now() + interval '30 seconds'
                                ELSE available_at
                            END,
                            locked_at = NULL,
                            locked_by = NULL,
                            last_error_code = 'worker_processing_error',
                            updated_at = now()
                        WHERE id = :id
                    """),
                    {
                        "id": job_id,
                        "status": "queued" if retry else "failed",
                        "retry": retry,
                    },
                )

                await db.execute(
                    text("""
                        UPDATE contents
                        SET analysis_status = :status,
                            updated_at = now()
                        WHERE id = :id
                    """),
                    {
                        "id": content_id,
                        "status": "pending" if retry else "failed",
                    },
                )

        return False


# 4. Worker 실행 루프
async def main():
    import uuid

    logger.info("ITDA Worker starting")

    engine, session_factory = create_worker_session_factory()
    worker_id = f"worker-{uuid.uuid4()}"

    try:
        while True:
            processed = await process_pending_jobs(
                session_factory,
                worker_id,
            )

            if not processed:
                await asyncio.sleep(2)

    finally:
        await engine.dispose()
        logger.info("ITDA Worker database engine disposed")


if __name__ == "__main__":
    asyncio.run(main())
