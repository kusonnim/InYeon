import json
import logging
from typing import Optional, Dict, Any, List
from uuid import UUID, uuid4
from datetime import datetime, timezone
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import text
from app.errors import ApiError
import hashlib
from sqlalchemy.exc import IntegrityError, DBAPIError
import base64

logger = logging.getLogger(__name__)

class PostgresRepository:
    """ ?ㅼ젣 PostgreSQL DB ?곕룞 諛?Fixture/Test ?명솚 ?명꽣?섏씠???대뙌??"""

    def __init__(self, db: Optional[AsyncSession] = None, seed: Optional[int] = None, *args, **kwargs):
        self.db = db
        self.seed = seed
        self.contents: Dict[str, Any] = {}
        self.preferences: Dict[str, Any] = {}
        self.feedback_events: List[Any] = []
        self._idempotency_records: Dict[str, Any] = {}

# 1. Fixture &amp; Router ?명솚 ?명꽣?섏씠??(once, owned, patch_content ??
    def once(
        self,
        user: str,
        domain: str,
        key: Optional[str],
        payload: Any,
        producer_fn: Any
    ) -> Any:
        if not key:
            return producer_fn()

        cache_key = f"{user}:{domain}:{key}"

        if cache_key in self._idempotency_records:
            saved_payload, saved_result = self._idempotency_records[cache_key]

            if saved_payload != payload:
                raise ApiError(
                    409,
                    "idempotency_conflict",
                    "Idempotency key reused with different payload"
                )

            return saved_result

        result = producer_fn()
        self._idempotency_records[cache_key] = (payload, result)
        return result

    def create(self, user: str, value: Any) -> Dict[str, Any]:
        """ ?몃찓紐⑤━ 肄섑뀗痢??앹꽦 """
        content_id = str(uuid4())
        created_at = datetime.now(timezone.utc).isoformat()
        item = {
            "id": content_id,
            "user_id": user,
            "title": getattr(value, "title", None) or "?쒕ぉ ?놁쓬",
            "source_url": str(value.source_url) if getattr(value, "source_url", None) else None,
            "content_text": getattr(value, "content_text", getattr(value, "raw_text", "")),
            "status": "PENDING",
            "version": 1,
            "created_at": created_at,
        }
        self.contents[content_id] = item
        return item

    def owned(self, user: str, content_id: Any) -> Dict[str, Any]:
        cid = str(content_id)
        item = self.contents.get(cid)

        if not item or str(item.get("user_id")) != str(user):
            raise ApiError(404, "not_found", "Content not found")

        return item

    def patch_content(self, user: str, content_id: Any, value: Any) -> Dict[str, Any]:
        """ 肄섑뀗痢?踰꾩쟾 寃利?諛??섏젙 """
        item = self.owned(user, content_id)
        expected_ver = getattr(value, "expected_version", None)
        if expected_ver is not None and item.get("version", 1) != expected_ver:
            raise ApiError(409, "version_conflict", f"Version mismatch: expected {expected_ver}, got {item.get('version')}")
        if hasattr(value, "title") and value.title is not None:
            item["title"] = value.title
        if hasattr(value, "user_note") and value.user_note is not None:
            item["user_note"] = value.user_note
            item["version"] = item.get("version", 1) + 1
        return item

    def patch_recommendation(self, user: str, rec_id: Any, value: Any) -> Dict[str, Any]:
        """ 異붿쿇 ??ぉ ?섏젙 """
        return {
            "id": str(rec_id),
            "content_id": str(uuid4()),
            "user_id": user,
            "category": "action",
            "title": "異붿쿇 ??ぉ",
            "why": "?ъ쑀",
            "accepted": getattr(value, "accepted", True),
            "user_text": getattr(value, "user_text", None),
            "version": getattr(value, "expected_version", 1) + 1
        }


    async def create_feedback(
        self,
        db: Optional[AsyncSession] = None,
        user_id: str = "fixture-user-a",
        idempotency_key: Optional[str] = None,
        feedback_data: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        session = db or self.db

        if not session:
            raise ApiError(
                503,
                "database_unavailable",
                "Database connection is not configured",
            )

        operation = "create-feedback"
        feedback_data = feedback_data or {}

        canonical_request = json.dumps(
            feedback_data,
            sort_keys=True,
            ensure_ascii=False,
            separators=(",", ":"),
        )
        request_hash = hashlib.sha256(
            canonical_request.encode("utf-8")
        ).hexdigest()

        try:
            async with session.begin():
                if idempotency_key:
                    existing = await self.get_idempotency(
                        db=session,
                        idempotency_key=idempotency_key,
                        user_id=user_id,
                        operation=operation,
                    )

                    if existing:
                        if existing["request_hash"] != request_hash:
                            raise ApiError(
                                409,
                                "idempotency_conflict",
                                "The idempotency key was already used with a different request",
                            )
                        return existing["response_body"]

                result = await session.execute(
                    text("""
                        INSERT INTO public.feedback_events (
                            user_id,
                            content_id,
                            recommendation_id,
                            event_type,
                            comment
                        )
                        VALUES (
                            :user_id,
                            :content_id,
                            :recommendation_id,
                            :event_type,
                            :comment
                        )
                        RETURNING
                            id,
                            user_id,
                            content_id,
                            recommendation_id,
                            event_type,
                            comment,
                            created_at
                    """),
                    {
                        "user_id": user_id,
                        "content_id": feedback_data["content_id"],
                        "recommendation_id": feedback_data.get(
                            "recommendation_id"
                        ),
                        "event_type": feedback_data["event_type"],
                        "comment": feedback_data.get("comment"),
                    },
                )

                row = result.mappings().one()

                response_body = {
                    "id": str(row["id"]),
                    "user_id": str(row["user_id"]),
                    "content_id": str(row["content_id"]),
                    "recommendation_id": (
                        str(row["recommendation_id"])
                        if row["recommendation_id"] else None
                    ),
                    "event_type": row["event_type"],
                    "comment": row["comment"],
                    "created_at": row["created_at"].isoformat(),
                }

                if idempotency_key:
                    await session.execute(
                        text("""
                            INSERT INTO public.idempotency_records (
                                user_id,
                                operation,
                                idempotency_key,
                                request_hash,
                                response_status,
                                response_body
                            )
                            VALUES (
                                :user_id,
                                :operation,
                                :key,
                                :request_hash,
                                201,
                                CAST(:response_body AS jsonb)
                            )
                        """),
                        {
                            "user_id": user_id,
                            "operation": operation,
                            "key": idempotency_key,
                            "request_hash": request_hash,
                            "response_body": json.dumps(
                                response_body,
                                ensure_ascii=False,
                            ),
                        },
                    )

            return response_body

        except IntegrityError:
            if idempotency_key:
                existing = await self.get_idempotency(
                    db=session,
                    idempotency_key=idempotency_key,
                    user_id=user_id,
                    operation=operation,
                )

                if existing:
                    if existing["request_hash"] != request_hash:
                        raise ApiError(
                            409,
                            "idempotency_conflict",
                            "The idempotency key was already used with a different request",
                        )
                    return existing["response_body"]

            raise

    def get_preferences(self, user: str) -> Dict[str, Any]:
        if user not in self.preferences:
            self.preferences[user] = {
                "user_id": user,
                "mbti": None,
                "preferred_topics": [],
                "disliked_topics": [],
                "version": 1
            }

        return self.preferences[user]

    def patch_preferences(self, user: str, value: Any) -> Dict[str, Any]:
        """ 痍⑦뼢 ?ㅼ젙 ?섏젙 """
        pref = self.get_preferences(user)
        expected_ver = getattr(value, "expected_version", None)
        if expected_ver is not None and pref.get("version", 1) != expected_ver:
            raise ApiError(409, "version_conflict", "Version mismatch")
        if hasattr(value, "mbti") and value.mbti is not None:
            pref["mbti"] = value.mbti
        if hasattr(value, "preferred_topics") and value.preferred_topics is not None:
            pref["preferred_topics"] = value.preferred_topics
        if hasattr(value, "disliked_topics") and value.disliked_topics is not None:
            pref["disliked_topics"] = value.disliked_topics

        pref["version"] = pref.get("version", 1) + 1
        return pref


    async def _run_notification_transition(
        self,
        db: Optional[AsyncSession],
        user_id: str,
        idempotency_key: Optional[str],
        operation: str,
        request_data: Dict[str, Any],
        sql: str,
        params: Dict[str, Any],
    ) -> Dict[str, Any]:
        session = db or self.db

        if not session:
            raise ApiError(
                503,
                "database_unavailable",
                "Database connection is not configured",
            )

        canonical_request = json.dumps(
            request_data,
            sort_keys=True,
            ensure_ascii=False,
            separators=(",", ":"),
        )
        request_hash = hashlib.sha256(
            canonical_request.encode("utf-8")
        ).hexdigest()

        try:
            async with session.begin():
                if idempotency_key:
                    existing = await self.get_idempotency(
                        db=session,
                        idempotency_key=idempotency_key,
                        user_id=user_id,
                        operation=operation,
                    )

                    if existing:
                        if existing["request_hash"] != request_hash:
                            raise ApiError(
                                409,
                                "idempotency_conflict",
                                "The idempotency key was already used with a different request",
                            )
                        return existing["response_body"]

                result = await session.execute(text(sql), params)
                response_body = result.scalar_one()

                if isinstance(response_body, str):
                    response_body = json.loads(response_body)

                if idempotency_key:
                    await session.execute(
                        text("""
                            INSERT INTO public.idempotency_records (
                                user_id,
                                operation,
                                idempotency_key,
                                request_hash,
                                response_status,
                                response_body
                            )
                            VALUES (
                                :user_id,
                                :operation,
                                :key,
                                :request_hash,
                                200,
                                CAST(:response_body AS jsonb)
                            )
                        """),
                        {
                            "user_id": user_id,
                            "operation": operation,
                            "key": idempotency_key,
                            "request_hash": request_hash,
                            "response_body": json.dumps(
                                response_body,
                                ensure_ascii=False,
                            ),
                        },
                    )

            return response_body

        except IntegrityError:
            if idempotency_key:
                existing = await self.get_idempotency(
                    db=session,
                    idempotency_key=idempotency_key,
                    user_id=user_id,
                    operation=operation,
                )

                if existing:
                    if existing["request_hash"] != request_hash:
                        raise ApiError(
                            409,
                            "idempotency_conflict",
                            "The idempotency key was already used with a different request",
                        )
                    return existing["response_body"]

            raise

        except DBAPIError as exc:
            original = exc.orig
            sqlstate = (
                getattr(original, "sqlstate", None)
                or getattr(original, "pgcode", None)
            )

            if sqlstate == "P0002":
                raise ApiError(404, "not_found", "Notification not found") from exc

            if sqlstate == "P0001":
                raise ApiError(
                    409,
                    "notification_conflict",
                    "Notification version conflict",
                ) from exc

            if sqlstate == "22004":
                raise ApiError(
                    422,
                    "version_required",
                    "Notification versions are required",
                ) from exc

            raise

    async def notification_event(
        self,
        db: Optional[AsyncSession] = None,
        user_id: str = "fixture-user-a",
        idempotency_key: Optional[str] = None,
        event_data: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        event_data = event_data or {}

        return await self._run_notification_transition(
            db=db,
            user_id=user_id,
            idempotency_key=idempotency_key,
            operation="notification-event",
            request_data=event_data,
            sql="""
                SELECT public.dismiss_notification(
                    CAST(:user_id AS uuid),
                    CAST(:content_id AS uuid),
                    CAST(:generation AS bigint),
                    CAST(:expected_revision AS bigint)
                ) AS result
            """,
            params={
                "user_id": user_id,
                "content_id": event_data["content_id"],
                "generation": event_data["generation"],
                "expected_revision": event_data["expected_revision"],
            },
        )

    async def restore_notification(
        self,
        db: Optional[AsyncSession] = None,
        user_id: str = "fixture-user-a",
        content_id: str = "",
        idempotency_key: Optional[str] = None,
        restore_data: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        restore_data = restore_data or {}

        return await self._run_notification_transition(
            db=db,
            user_id=user_id,
            idempotency_key=idempotency_key,
            operation=f"restore:{content_id}",
            request_data={
                "content_id": content_id,
                **restore_data,
            },
            sql="""
                SELECT public.restore_notification(
                    CAST(:user_id AS uuid),
                    CAST(:content_id AS uuid),
                    CAST(:expected_generation AS bigint),
                    CAST(:expected_revision AS bigint)
                ) AS result
            """,
            params={
                "user_id": user_id,
                "content_id": content_id,
                "expected_generation": restore_data["expected_generation"],
                "expected_revision": restore_data["expected_revision"],
            },
        )

    async def sync(self, user: str, cursor: Optional[str] = None, limit: int = 20) -> Dict[str, Any]:
        """동기화 이벤트 목록 조회"""
        return {
            "items": [],
            "next_cursor": None,
            "has_more": False
        }

# 2. 鍮꾨룞湲?PostgreSQL DB ?곕룞 硫붿꽌??

    async def get_idempotency(
        self,
        db: Optional[AsyncSession] = None,
        idempotency_key: Optional[str] = None,
        user_id: Optional[str] = None,
        operation: str = "create-content",
    ) -> Optional[Dict[str, Any]]:
        session = db or self.db
        if not session or not idempotency_key or not user_id:
            return None

        result = await session.execute(
            text("""
                SELECT request_hash, response_body
                FROM public.idempotency_records
                WHERE user_id = :user_id
                  AND operation = :operation
                  AND idempotency_key = :key
            """),
            {
                "user_id": user_id,
                "operation": operation,
                "key": idempotency_key,
            },
        )
        row = result.fetchone()

        if not row:
            return None

        response_body = row[1]
        if isinstance(response_body, str):
            response_body = json.loads(response_body)

        return {
            "request_hash": row[0],
            "response_body": response_body,
        }

    async def create_content(
        self,
        db: Optional[AsyncSession] = None,
        user_id: str = "fixture-user-a",
        idempotency_key: Optional[str] = None,
        content_data: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        session = db or self.db

        if not session:
            raise ApiError(
                503,
                "database_unavailable",
                "Database connection is not configured",
            )

        operation = "create-content"
        content_data = content_data or {}

        canonical_request = json.dumps(
            content_data,
            sort_keys=True,
            ensure_ascii=False,
            separators=(",", ":"),
        )
        request_hash = hashlib.sha256(
            canonical_request.encode("utf-8")
        ).hexdigest()

        try:
            async with session.begin():
                if idempotency_key:
                    existing = await self.get_idempotency(
                        db=session,
                        idempotency_key=idempotency_key,
                        user_id=user_id,
                        operation=operation,
                    )

                    if existing:
                        if existing["request_hash"] != request_hash:
                            raise ApiError(
                                409,
                                "idempotency_conflict",
                                "The idempotency key was already used with a different request",
                            )
                        return existing["response_body"]

                input_type = content_data["input_type"]
                source_text = content_data.get("source_text")
                source_url = content_data.get("source_url")
                asset_ids = content_data.get("asset_ids", [])

                # 泥⑤??뚯씪???덉쑝硫??뚯쑀沅? ?낅줈???꾨즺 ?щ?,
                # 湲곗〈 肄섑뀗痢??곌껐 ?щ?瑜?癒쇱? 寃利앺븳??
                asset_rows = []

                if asset_ids:
                    asset_result = await session.execute(
                        text("""
                            SELECT id, media_type
                            FROM public.content_assets
                            WHERE user_id = :user_id
                              AND id = ANY(CAST(:asset_ids AS uuid[]))
                              AND status = 'ready'
                              AND content_id IS NULL
                            FOR UPDATE
                        """),
                        {
                            "user_id": user_id,
                            "asset_ids": asset_ids,
                        },
                    )
                    asset_rows = asset_result.fetchall()

                    if len(asset_rows) != len(asset_ids):
                        raise ApiError(
                            409,
                            "asset_unavailable",
                            "One or more assets are unavailable or already linked",
                        )

                    allowed_types = (
                        {"image/jpeg", "image/png", "image/webp"}
                        if input_type == "image"
                        else {"application/pdf", "text/plain"}
                        if input_type == "document"
                        else None
                    )

                    if allowed_types is not None:
                        if any(row[1] not in allowed_types for row in asset_rows):
                            raise ApiError(
                                422,
                                "asset_type_mismatch",
                                "Asset media type does not match input_type",
                            )

                # 肄섑뀗痢??앹꽦
                content_result = await session.execute(
                    text("""
                        INSERT INTO public.contents (
                            user_id,
                            input_type,
                            source_text,
                            source_url
                        )
                        VALUES (
                            :user_id,
                            :input_type,
                            :source_text,
                            :source_url
                        )
                        RETURNING id, created_at, updated_at, version
                    """),
                    {
                        "user_id": user_id,
                        "input_type": input_type,
                        "source_text": source_text,
                        "source_url": source_url,
                    },
                )
                content_row = content_result.fetchone()

                content_id = content_row[0]
                created_at = content_row[1]
                updated_at = content_row[2]
                version = content_row[3]

                # 寃利앸맂 泥⑤??뚯씪??肄섑뀗痢좎뿉 ?곌껐
                if asset_ids:
                    await session.execute(
                        text("""
                            UPDATE public.content_assets
                            SET content_id = :content_id
                            WHERE user_id = :user_id
                              AND id = ANY(CAST(:asset_ids AS uuid[]))
                              AND status = 'ready'
                              AND content_id IS NULL
                        """),
                        {
                            "content_id": content_id,
                            "user_id": user_id,
                            "asset_ids": asset_ids,
                        },
                    )

                # ?뚮┝ ?곹깭 湲곕낯媛??앹꽦
                notification_result = await session.execute(
                    text("""
                        INSERT INTO public.notification_states (
                            content_id,
                            user_id
                        )
                        VALUES (:content_id, :user_id)
                        RETURNING visibility, generation, revision, updated_at
                    """),
                    {
                        "content_id": content_id,
                        "user_id": user_id,
                    },
                )
                notification_row = notification_result.fetchone()

                # 遺꾩꽍 ?묒뾽 ?湲곗뿴 ?깅줉
                await session.execute(
                    text("""
                        INSERT INTO public.analysis_jobs (
                            content_id,
                            user_id,
                            status
                        )
                        VALUES (:content_id, :user_id, 'queued')
                    """),
                    {
                        "content_id": content_id,
                        "user_id": user_id,
                    },
                )

                # ?숆린???대깽?몃뒗 DB ?⑥닔濡??앹꽦
                await session.execute(
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

                response_body = {
                    "id": str(content_id),
                    "user_id": str(user_id),
                    "input_type": input_type,
                    "source_text": source_text,
                    "source_url": source_url,
                    "asset_ids": [str(asset_id) for asset_id in asset_ids],
                    "title": None,
                    "user_note": None,
                    "analysis_status": "pending",
                    "workflow_status": "pending",
                    "version": version,
                    "created_at": created_at.isoformat(),
                    "updated_at": updated_at.isoformat(),
                    "analysis": None,
                    "recommendations": [],
                    "notification": {
                        "content_id": str(content_id),
                        "visibility": notification_row[0],
                        "generation": notification_row[1],
                        "revision": notification_row[2],
                        "updated_at": notification_row[3].isoformat(),
                    },
                }

                # 硫깅벑???묐떟 湲곕줉
                if idempotency_key:
                    await session.execute(
                        text("""
                            INSERT INTO public.idempotency_records (
                                user_id,
                                operation,
                                idempotency_key,
                                request_hash,
                                response_status,
                                response_body
                            )
                            VALUES (
                                :user_id,
                                :operation,
                                :key,
                                :request_hash,
                                201,
                                CAST(:response_body AS jsonb)
                            )
                        """),
                        {
                            "user_id": user_id,
                            "operation": operation,
                            "key": idempotency_key,
                            "request_hash": request_hash,
                            "response_body": json.dumps(
                                response_body,
                                ensure_ascii=False,
                            ),
                        },
                    )

            return response_body

        except IntegrityError:
            # ?숈떆??媛숈? 硫깅벑???ㅺ? ?ㅼ뼱??寃쎌슦,
            # 癒쇱? 而ㅻ컠???붿껌??寃곌낵瑜??뺤씤?쒕떎.
            if idempotency_key:
                existing = await self.get_idempotency(
                    db=session,
                    idempotency_key=idempotency_key,
                    user_id=user_id,
                    operation=operation,
                )

                if existing:
                    if existing["request_hash"] != request_hash:
                        raise ApiError(
                            409,
                            "idempotency_conflict",
                            "The idempotency key was already used with a different request",
                        )
                    return existing["response_body"]

            raise


    async def get_content(
        self,
        db: AsyncSession,
        content_id: str,
        user_id: str,
    ) -> Optional[Dict[str, Any]]:
        query = text("""
            SELECT
                c.id::text AS id,
                c.user_id::text AS user_id,
                c.input_type,
                c.source_text,
                c.source_url,
                COALESCE((
                    SELECT json_agg(a.id::text ORDER BY a.created_at, a.id)
                    FROM public.content_assets a
                    WHERE a.content_id = c.id
                      AND a.user_id = c.user_id
                ), '[]'::json) AS asset_ids,
                c.title,
                c.user_note,
                c.analysis_status,
                c.workflow_status,
                c.version,
                c.created_at,
                c.updated_at,

                (
                    SELECT json_build_object(
                        'id', an.id,
                        'content_id', an.content_id,
                        'coverage', an.coverage,
                        'summary', an.summary,
                        'limitations', an.limitations,
                        'created_at', an.created_at
                    )
                    FROM public.analyses an
                    WHERE an.content_id = c.id
                      AND an.user_id = c.user_id
                ) AS analysis,

                COALESCE((
                    SELECT json_agg(
                        json_build_object(
                            'id', r.id,
                            'content_id', r.content_id,
                            'kind', r.kind,
                            'text', r.text,
                            'source_url', r.source_url,
                            'user_text', r.user_text,
                            'accepted', r.accepted,
                            'version', r.version,
                            'created_at', r.created_at,
                            'updated_at', r.updated_at
                        )
                        ORDER BY r.created_at, r.id
                    )
                    FROM public.recommendations r
                    WHERE r.content_id = c.id
                      AND r.user_id = c.user_id
                ), '[]'::json) AS recommendations,

                json_build_object(
                    'content_id', n.content_id,
                    'visibility', n.visibility,
                    'generation', n.generation,
                    'revision', n.revision,
                    'updated_at', n.updated_at
                ) AS notification

            FROM public.contents c
            JOIN public.notification_states n
              ON n.content_id = c.id
             AND n.user_id = c.user_id
            WHERE c.id = CAST(:content_id AS uuid)
              AND c.user_id = CAST(:user_id AS uuid)
        """)

        result = await db.execute(
            query,
            {
                "content_id": content_id,
                "user_id": user_id,
            },
        )

        row = result.mappings().first()
        return dict(row) if row else None

    async def list_contents(
        self,
        db: AsyncSession,
        user_id: str,
        limit: int = 20,
        cursor: Optional[str] = None,
    ) -> Dict[str, Any]:
        cursor_created_at = None
        cursor_id = None

        if cursor:
            try:
                padded = cursor.encode() + b"=" * (-len(cursor) % 4)
                decoded = json.loads(
                    base64.urlsafe_b64decode(padded).decode()
                )

                if decoded["user_id"] != str(user_id):
                    raise ValueError("Cursor owner mismatch")

                cursor_created_at = datetime.fromisoformat(
                    decoded["last_created_at"]
                )
                cursor_id = str(UUID(decoded["last_id"]))

            except (ValueError, TypeError, KeyError, UnicodeDecodeError):
                raise ApiError(
                    400,
                    "invalid_cursor",
                    "Invalid or expired cursor",
                )

        query = text("""
            SELECT
                c.id::text AS id,
                c.user_id::text AS user_id,
                c.input_type,
                c.source_text,
                c.source_url,
                COALESCE((
                    SELECT json_agg(a.id::text ORDER BY a.created_at, a.id)
                    FROM public.content_assets a
                    WHERE a.content_id = c.id
                      AND a.user_id = c.user_id
                ), '[]'::json) AS asset_ids,
                c.title,
                c.user_note,
                c.analysis_status,
                c.workflow_status,
                c.version,
                c.created_at,
                c.updated_at,

                (
                    SELECT json_build_object(
                        'id', an.id,
                        'content_id', an.content_id,
                        'coverage', an.coverage,
                        'summary', an.summary,
                        'limitations', an.limitations,
                        'created_at', an.created_at
                    )
                    FROM public.analyses an
                    WHERE an.content_id = c.id
                      AND an.user_id = c.user_id
                ) AS analysis,

                COALESCE((
                    SELECT json_agg(
                        json_build_object(
                            'id', r.id,
                            'content_id', r.content_id,
                            'kind', r.kind,
                            'text', r.text,
                            'source_url', r.source_url,
                            'user_text', r.user_text,
                            'accepted', r.accepted,
                            'version', r.version,
                            'created_at', r.created_at,
                            'updated_at', r.updated_at
                        )
                        ORDER BY r.created_at, r.id
                    )
                    FROM public.recommendations r
                    WHERE r.content_id = c.id
                      AND r.user_id = c.user_id
                ), '[]'::json) AS recommendations,

                json_build_object(
                    'content_id', n.content_id,
                    'visibility', n.visibility,
                    'generation', n.generation,
                    'revision', n.revision,
                    'updated_at', n.updated_at
                ) AS notification

            FROM public.contents c
            JOIN public.notification_states n
              ON n.content_id = c.id
             AND n.user_id = c.user_id

            WHERE c.user_id = CAST(:user_id AS uuid)
              AND (
                  CAST(:cursor_created_at AS timestamptz) IS NULL
                  OR (c.created_at, c.id) < (
                      CAST(:cursor_created_at AS timestamptz),
                      CAST(:cursor_id AS uuid)
                  )
              )

            ORDER BY c.created_at DESC, c.id DESC
            LIMIT :fetch_limit
        """)

        result = await db.execute(
            query,
            {
                "user_id": user_id,
                "cursor_created_at": cursor_created_at,
                "cursor_id": cursor_id,
                "fetch_limit": limit + 1,
            },
        )

        rows = [dict(row) for row in result.mappings().all()]

        has_more = len(rows) > limit
        items = rows[:limit]
        next_cursor = None

        if has_more and items:
            last_item = items[-1]

            payload = json.dumps({
                "user_id": str(user_id),
                "last_created_at": last_item["created_at"].isoformat(),
                "last_id": last_item["id"],
            }).encode()

            next_cursor = base64.urlsafe_b64encode(
                payload
            ).decode().rstrip("=")

        return {
            "items": items,
            "next_cursor": next_cursor,
        }

    async def get_preferences(
        self,
        db: AsyncSession,
        user_id: str,
    ) -> Dict[str, Any]:
        async with db.begin():
            await db.execute(
                text("""
                    INSERT INTO public.preferences (
                        user_id,
                        interests,
                        explicit_preferences,
                        mbti,
                        version,
                        created_at,
                        updated_at
                    )
                    VALUES (
                        CAST(:user_id AS uuid),
                        ARRAY[]::text[],
                        ARRAY[]::text[],
                        NULL,
                        1,
                        now(),
                        now()
                    )
                    ON CONFLICT (user_id) DO NOTHING
                """),
                {"user_id": str(user_id)},
            )

            result = await db.execute(
                text("""
                    SELECT
                        user_id::text AS user_id,
                        interests,
                        explicit_preferences,
                        mbti,
                        version,
                        created_at,
                        updated_at
                    FROM public.preferences
                    WHERE user_id = CAST(:user_id AS uuid)
                """),
                {"user_id": str(user_id)},
            )

            row = result.mappings().one()
            return dict(row)

    async def patch_preferences(
        self,
        db: AsyncSession,
        user_id: str,
        value: Any,
    ) -> Dict[str, Any]:
        fields = value.model_fields_set

        async with db.begin():
            await db.execute(
                text("""
                    INSERT INTO public.preferences (
                        user_id,
                        interests,
                        explicit_preferences,
                        mbti,
                        version,
                        created_at,
                        updated_at
                    )
                    VALUES (
                        CAST(:user_id AS uuid),
                        ARRAY[]::text[],
                        ARRAY[]::text[],
                        NULL,
                        1,
                        now(),
                        now()
                    )
                    ON CONFLICT (user_id) DO NOTHING
                """),
                {"user_id": str(user_id)},
            )

            result = await db.execute(
                text("""
                    SELECT version
                    FROM public.preferences
                    WHERE user_id = CAST(:user_id AS uuid)
                    FOR UPDATE
                """),
                {"user_id": str(user_id)},
            )

            row = result.mappings().one()
            current_version = row["version"]

            if current_version != value.expected_version:
                raise ApiError(
                    409,
                    "version_conflict",
                    "Preferences version does not match",
                    current_version=current_version,
                )

            await db.execute(
                text("""
                    UPDATE public.preferences
                    SET
                        interests = CASE
                            WHEN :update_interests
                            THEN CAST(:interests AS text[])
                            ELSE interests
                        END,
                        explicit_preferences = CASE
                            WHEN :update_explicit_preferences
                            THEN CAST(:explicit_preferences AS text[])
                            ELSE explicit_preferences
                        END,
                        mbti = CASE
                            WHEN :update_mbti
                            THEN CAST(:mbti AS text)
                            ELSE mbti
                        END,
                        version = version + 1,
                        updated_at = now()
                    WHERE user_id = CAST(:user_id AS uuid)
                """),
                {
                    "user_id": str(user_id),
                    "update_interests": "interests" in fields,
                    "interests": value.interests,
                    "update_explicit_preferences": (
                        "explicit_preferences" in fields
                    ),
                    "explicit_preferences": value.explicit_preferences,
                    "update_mbti": "mbti" in fields,
                    "mbti": value.mbti,
                },
            )

            updated = await db.execute(
                text("""
                    SELECT
                        user_id::text AS user_id,
                        interests,
                        explicit_preferences,
                        mbti,
                        version,
                        created_at,
                        updated_at
                    FROM public.preferences
                    WHERE user_id = CAST(:user_id AS uuid)
                """),
                {"user_id": str(user_id)},
            )

            return dict(updated.mappings().one())

    async def patch_content(
        self,
        db: AsyncSession,
        user_id: str,
        content_id: str,
        value: Any,
    ) -> Dict[str, Any]:
        fields = value.model_fields_set

        async with db.begin():
            result = await db.execute(
                text("""
                    SELECT version
                    FROM public.contents
                    WHERE id = CAST(:content_id AS uuid)
                      AND user_id = CAST(:user_id AS uuid)
                    FOR UPDATE
                """),
                {
                    "content_id": str(content_id),
                    "user_id": str(user_id),
                },
            )
            row = result.mappings().first()

            if row is None:
                raise ApiError(404, "not_found", "Content not found")

            current_version = row["version"]

            if current_version != value.expected_version:
                raise ApiError(
                    409,
                    "version_conflict",
                    "Content version does not match",
                    current_version=current_version,
                )

            await db.execute(
                text("""
                    UPDATE public.contents
                    SET
                        title = CASE
                            WHEN :update_title THEN :title
                            ELSE title
                        END,
                        user_note = CASE
                            WHEN :update_user_note THEN :user_note
                            ELSE user_note
                        END,
                        workflow_status = CASE
                            WHEN :update_workflow_status THEN :workflow_status
                            ELSE workflow_status
                        END,
                        version = version + 1,
                        updated_at = now()
                    WHERE id = CAST(:content_id AS uuid)
                      AND user_id = CAST(:user_id AS uuid)
                """),
                {
                    "content_id": str(content_id),
                    "user_id": str(user_id),
                    "update_title": "title" in fields,
                    "title": value.title,
                    "update_user_note": "user_note" in fields,
                    "user_note": value.user_note,
                    "update_workflow_status": "workflow_status" in fields,
                    "workflow_status": value.workflow_status,
                },
            )

            updated = await db.execute(
                text("""
                    SELECT
                        id::text AS id,
                        user_id::text AS user_id,
                        input_type,
                        source_text,
                        source_url,
                        title,
                        user_note,
                        analysis_status,
                        workflow_status,
                        version,
                        created_at,
                        updated_at
                    FROM public.contents
                    WHERE id = CAST(:content_id AS uuid)
                      AND user_id = CAST(:user_id AS uuid)
                """),
                {
                    "content_id": str(content_id),
                    "user_id": str(user_id),
                },
            )

            return dict(updated.mappings().one())
    async def patch_recommendation(
        self,
        db: AsyncSession,
        user_id: str,
        recommendation_id: str,
        value: Any,
    ) -> Dict[str, Any]:
        fields = value.model_fields_set

        async with db.begin():
            target = await db.execute(
                text("""
                    SELECT content_id::text AS content_id
                    FROM public.recommendations
                    WHERE id = CAST(:recommendation_id AS uuid)
                      AND user_id = CAST(:user_id AS uuid)
                """),
                {
                    "recommendation_id": str(recommendation_id),
                    "user_id": str(user_id),
                },
            )
            target_row = target.mappings().first()

            if target_row is None:
                raise ApiError(
                    404,
                    "not_found",
                    "Recommendation not found",
                )

            content_id = target_row["content_id"]

            content = await db.execute(
                text("""
                    SELECT id
                    FROM public.contents
                    WHERE id = CAST(:content_id AS uuid)
                      AND user_id = CAST(:user_id AS uuid)
                    FOR UPDATE
                """),
                {
                    "content_id": content_id,
                    "user_id": str(user_id),
                },
            )

            if content.mappings().first() is None:
                raise ApiError(
                    404,
                    "not_found",
                    "Content not found",
                )

            current = await db.execute(
                text("""
                    SELECT version
                    FROM public.recommendations
                    WHERE id = CAST(:recommendation_id AS uuid)
                      AND content_id = CAST(:content_id AS uuid)
                      AND user_id = CAST(:user_id AS uuid)
                    FOR UPDATE
                """),
                {
                    "recommendation_id": str(recommendation_id),
                    "content_id": content_id,
                    "user_id": str(user_id),
                },
            )
            current_row = current.mappings().first()

            if current_row is None:
                raise ApiError(
                    404,
                    "not_found",
                    "Recommendation not found",
                )

            current_version = current_row["version"]

            if current_version != value.expected_version:
                raise ApiError(
                    409,
                    "version_conflict",
                    "Recommendation version does not match",
                    current_version=current_version,
                )

            await db.execute(
                text("""
                    UPDATE public.recommendations
                    SET
                        user_text = CASE
                            WHEN :update_user_text THEN :user_text
                            ELSE user_text
                        END,
                        accepted = CASE
                            WHEN :update_accepted THEN :accepted
                            ELSE accepted
                        END,
                        version = version + 1,
                        updated_at = now()
                    WHERE id = CAST(:recommendation_id AS uuid)
                      AND content_id = CAST(:content_id AS uuid)
                      AND user_id = CAST(:user_id AS uuid)
                """),
                {
                    "recommendation_id": str(recommendation_id),
                    "content_id": content_id,
                    "user_id": str(user_id),
                    "update_user_text": "user_text" in fields,
                    "user_text": value.user_text,
                    "update_accepted": "accepted" in fields,
                    "accepted": value.accepted,
                },
            )

            await db.execute(
                text("""
                    UPDATE public.contents
                    SET
                        version = version + 1,
                        updated_at = now()
                    WHERE id = CAST(:content_id AS uuid)
                      AND user_id = CAST(:user_id AS uuid)
                """),
                {
                    "content_id": content_id,
                    "user_id": str(user_id),
                },
            )

            if "accepted" in fields:
                await db.execute(
                    text("""
                        INSERT INTO public.feedback_events (
                            user_id,
                            content_id,
                            recommendation_id,
                            event_type,
                            comment
                        )
                        VALUES (
                            CAST(:user_id AS uuid),
                            CAST(:content_id AS uuid),
                            CAST(:recommendation_id AS uuid),
                            :event_type,
                            NULL
                        )
                    """),
                    {
                        "user_id": str(user_id),
                        "content_id": content_id,
                        "recommendation_id": str(recommendation_id),
                        "event_type": (
                            "accepted" if value.accepted else "rejected"
                        ),
                    },
                )

            await db.execute(
                text("""
                    SELECT public.append_sync_event(
                        CAST(:user_id AS uuid),
                        'recommendation',
                        CAST(:recommendation_id AS uuid),
                        'upsert',
                        CAST(:content_id AS uuid)
                    )
                """),
                {
                    "user_id": str(user_id),
                    "recommendation_id": str(recommendation_id),
                    "content_id": content_id,
                },
            )

            updated = await db.execute(
                text("""
                    SELECT
                        id,
                        content_id,
                        kind,
                        text,
                        source_url,
                        user_text,
                        accepted,
                        version,
                        created_at,
                        updated_at
                    FROM public.recommendations
                    WHERE id = CAST(:recommendation_id AS uuid)
                      AND user_id = CAST(:user_id AS uuid)
                """),
                {
                    "recommendation_id": str(recommendation_id),
                    "user_id": str(user_id),
                },
            )

            return dict(updated.mappings().one())

class FixtureRepository:
    """?뚯뒪???꾩슜 硫붾え由???μ냼. 理쒖떊 Pydantic 紐⑤뜽 怨꾩빟???곕Ⅸ??"""

    USER_A = "00000000-0000-4000-8000-000000000001"
    USER_B = "00000000-0000-4000-8000-000000000002"

    def __init__(self, seed=True, *args, **kwargs):
        from threading import RLock

        self._lock = RLock()
        self.contents = {}
        self.preferences = {}
        self.jobs = []
        self.feedback = []
        self.sync_events = []
        self._idempotency_records = {}
        self._sequence = 0

        if seed:
            self._seed()

    @staticmethod
    def _now():
        return datetime.now(timezone.utc).isoformat()

    @classmethod
    def _user_id(cls, user):
        value = str(user)
        if value == "fixture-user-a":
            return cls.USER_A
        if value == "fixture-user-b":
            return cls.USER_B
        return value

    @staticmethod
    def _uuid(value):
        return str(value)

    def _seed(self):
        now = self._now()
        content_ids = [
            "10000000-0000-4000-8000-000000000001",
            "10000000-0000-4000-8000-000000000002",
            "10000000-0000-4000-8000-000000000003",
            "10000000-0000-4000-8000-000000000004",
        ]
        user_id = self.USER_A

        for index, content_id in enumerate(content_ids):
            recommendation_id = (
                f"20000000-0000-4000-8000-{index + 1:012d}"
            )
            analysis_id = (
                f"30000000-0000-4000-8000-{index + 1:012d}"
            )

            analysis = None
            recommendations = []

            if index != 3:
                analysis = {
                    "id": analysis_id,
                    "content_id": content_id,
                    "coverage": "full_text",
                    "summary": "?뚯뒪?몄슜 遺꾩꽍 寃곌낵",
                    "limitations": [],
                    "created_at": now,
                }

            if index == 3:
                analysis = {
                    "id": analysis_id,
                    "content_id": content_id,
                    "coverage": "metadata_only",
                    "summary": None,
                    "limitations": ["?먮Ц???쒓났?섏? ?딆븯?듬땲??"],
                    "created_at": now,
                }

            if index == 0:
                recommendations = [
                    {
                        "id": recommendation_id,
                        "content_id": content_id,
                        "kind": "action",
                        "text": "?뚯뒪??異붿쿇 ??ぉ",
                        "source_url": None,
                        "user_text": None,
                        "accepted": False,
                        "version": 1,
                        "created_at": now,
                        "updated_at": now,
                    }
                ]

            self.contents[content_id] = {
                "id": content_id,
                "user_id": user_id,
                "input_type": "text",
                "source_text": f"?뚯뒪???먮Ц {index + 1}",
                "source_url": None,
                "asset_ids": [],
                "title": f"?뚯뒪??肄섑뀗痢?{index + 1}",
                "user_note": None,
                "analysis_status": "completed" if analysis else "pending",
                "workflow_status": "pending",
                "version": 2 if index == 0 else 1,
                "created_at": now,
                "updated_at": now,
                "analysis": analysis,
                "recommendations": recommendations,
                "notification": {
                    "content_id": content_id,
                    "visibility": "active",
                    "generation": 1,
                    "revision": 2 if index == 0 else 1,
                    "updated_at": now,
                },
            }

    def _record_sync(self, entity_type, entity_id, content_id=None):
        self._sequence += 1

        entity_id = str(entity_id)
        content_id = str(content_id) if content_id else None

        user_id = None
        if content_id and content_id in self.contents:
            user_id = self.contents[content_id]["user_id"]
        elif entity_type == "preferences":
            user_id = entity_id

        self.sync_events.append({
            "user_id": user_id,
            "sequence": str(self._sequence),
            "entity_type": entity_type,
            "entity_id": entity_id,
            "content_id": content_id,
            "operation": "upsert",
            "occurred_at": self._now(),
        })

    def once(self, user, domain, key, payload, producer_fn):
        if not key:
            return producer_fn()

        cache_key = f"{user}:{domain}:{key}"

        with self._lock:
            if cache_key in self._idempotency_records:
                saved_payload, saved_result = self._idempotency_records[cache_key]
                if saved_payload != payload:
                    raise ApiError(
                        409,
                        "idempotency_conflict",
                        "Idempotency key reused with different payload",
                    )
                return saved_result

            result = producer_fn()
            self._idempotency_records[cache_key] = (payload, result)
            return result

    def create(self, user, value):
        with self._lock:
            user_id = self._user_id(user)
            content_id = str(uuid4())
            now = self._now()

            item = {
                "id": content_id,
                "user_id": user_id,
                "input_type": value.input_type,
                "source_text": value.source_text,
                "source_url": str(value.source_url) if value.source_url else None,
                "asset_ids": [str(x) for x in value.asset_ids],
                "title": None,
                "user_note": None,
                "analysis_status": "pending",
                "workflow_status": "pending",
                "version": 1,
                "created_at": now,
                "updated_at": now,
                "analysis": None,
                "recommendations": [],
                "notification": {
                    "content_id": content_id,
                    "visibility": "active",
                    "generation": 1,
                    "revision": 1,
                    "updated_at": now,
                },
            }

            self.contents[content_id] = item
            self.jobs.append({
                "id": str(uuid4()),
                "user_id": user_id,
                "content_id": content_id,
                "status": "queued",
                "attempts": 0,
                "created_at": now,
            })
            self._record_sync("content", content_id, content_id)
            return item

    def owned(self, user, content_id):
        item = self.contents.get(str(content_id))
        user_id = self._user_id(user)

        if not item or item["user_id"] != user_id:
            raise ApiError(404, "not_found", "Content not found")
        return item

    def patch_content(self, user, content_id, value):
        with self._lock:
            item = self.owned(user, content_id)
            expected = value.expected_version

            if item["version"] != expected:
                raise ApiError(
                    409,
                    "version_conflict",
                    "Content version does not match",
                    current_version=item["version"],
                )

            fields = value.model_fields_set

            if "title" in fields:
                item["title"] = value.title
            if "user_note" in fields:
                item["user_note"] = value.user_note
            if "workflow_status" in fields:
                item["workflow_status"] = value.workflow_status

            item["version"] += 1
            item["updated_at"] = self._now()
            self._record_sync("content", item["id"], item["id"])
            return item

    def _find_recommendation(self, user, recommendation_id):
        for content in self.contents.values():
            if content["user_id"] != self._user_id(user):
                continue
            for recommendation in content["recommendations"]:
                if recommendation["id"] == str(recommendation_id):
                    return content, recommendation

        raise ApiError(404, "not_found", "Recommendation not found")

    def patch_recommendation(self, user, rec_id, value):
        with self._lock:
            content, rec = self._find_recommendation(user, rec_id)

            if rec["version"] != value.expected_version:
                raise ApiError(
                    409,
                    "version_conflict",
                    "Recommendation version does not match",
                    current_version=rec["version"],
                )

            fields = value.model_fields_set
            if "user_text" in fields:
                rec["user_text"] = value.user_text
            if "accepted" in fields and value.accepted is not None:
                rec["accepted"] = value.accepted

            rec["version"] += 1
            rec["updated_at"] = self._now()
            content["version"] += 1
            content["updated_at"] = self._now()

            if "accepted" in fields and value.accepted is not None:
                self.feedback.append({
                    "id": str(uuid4()),
                    "user_id": content["user_id"],
                    "content_id": content["id"],
                    "recommendation_id": rec["id"],
                    "event_type": "accepted" if value.accepted else "rejected",
                    "comment": None,
                    "created_at": self._now(),
                })

            self._record_sync("recommendation", rec["id"], content["id"])
            return rec

    def add_feedback(self, user, value):
        content = self.owned(user, value.content_id)

        if value.recommendation_id:
            self._find_recommendation(user, value.recommendation_id)

        event = {
            "id": str(uuid4()),
            "user_id": content["user_id"],
            "content_id": str(value.content_id),
            "recommendation_id": (
                str(value.recommendation_id) if value.recommendation_id else None
            ),
            "event_type": value.event_type,
            "comment": value.comment,
            "created_at": self._now(),
        }
        self.feedback.append(event)
        return event

    def get_preferences(self, user):
        user_id = self._user_id(user)
        if user_id not in self.preferences:
            now = self._now()
            self.preferences[user_id] = {
                "user_id": user_id,
                "interests": [],
                "explicit_preferences": [],
                "mbti": None,
                "version": 1,
                "created_at": now,
                "updated_at": now,
            }
        return self.preferences[user_id]

    def patch_preferences(self, user, value):
        with self._lock:
            pref = self.get_preferences(user)

            if pref["version"] != value.expected_version:
                raise ApiError(
                    409,
                    "version_conflict",
                    "Preferences version does not match",
                    current_version=pref["version"],
                )

            fields = value.model_fields_set
            for field in ("interests", "explicit_preferences", "mbti"):
                if field in fields:
                    pref[field] = getattr(value, field)

            pref["version"] += 1
            pref["updated_at"] = self._now()
            self._record_sync("preferences", pref["user_id"])
            return pref

    def notification_event(self, user, value):
        with self._lock:
            content = self.owned(user, value.content_id)
            state = content["notification"]

            if value.generation < state["generation"]:
                return {
                    "state": state,
                    "applied": False,
                    "reason": "stale_generation",
                }

            if value.generation > state["generation"]:
                raise ApiError(409, "notification_conflict", "Future generation")

            if value.expected_revision != state["revision"]:
                raise ApiError(409, "notification_conflict", "Revision mismatch")

            if state["visibility"] == "dismissed":
                return {
                    "state": state,
                    "applied": False,
                    "reason": "already_dismissed",
                }

            state["visibility"] = "dismissed"
            state["revision"] += 1
            state["updated_at"] = self._now()
            self._record_sync("notification", content["id"], content["id"])

            return {"state": state, "applied": True, "reason": "applied"}

    def restore(self, user, content_id, value):
        with self._lock:
            content = self.owned(user, content_id)
            state = content["notification"]

            if (
                value.expected_generation != state["generation"]
                or value.expected_revision != state["revision"]
            ):
                raise ApiError(409, "notification_conflict", "Notification version mismatch")

            if state["visibility"] == "active":
                return {
                    "state": state,
                    "applied": False,
                    "reason": "already_active",
                }

            state["visibility"] = "active"
            state["generation"] += 1
            state["revision"] += 1
            state["updated_at"] = self._now()
            self._record_sync("notification", content["id"], content["id"])

            return {"state": state, "applied": True, "reason": "applied"}

    def apply_analysis(self, user, content_id, analysis, recommendations, status):
        with self._lock:
            content = self.owned(user, content_id)
            content["analysis"] = analysis
            content["analysis_status"] = status

            if recommendations is not None:
                old = {
                    rec["id"]: rec
                    for rec in content["recommendations"]
                }
                updated = []
                for rec in recommendations:
                    rec_data = (
                        rec.model_dump(mode="json")
                        if hasattr(rec, "model_dump")
                        else dict(rec)
                    )
                    previous = old.get(rec_data["id"])
                    if previous:
                        rec_data["accepted"] = previous["accepted"]
                        rec_data["user_text"] = previous["user_text"]
                    updated.append(rec_data)
                content["recommendations"] = updated

            content["version"] += 1
            content["updated_at"] = self._now()
            self._record_sync("content", content["id"], content["id"])
            return content

    def list_contents(self, user, cursor=None, limit=20):
        user_id = self._user_id(user)
        items = [
            item for item in self.contents.values()
            if item["user_id"] == user_id
        ]
        items.sort(
            key=lambda item: (item["created_at"], item["id"]),
            reverse=True,
        )

        start = 0
        if cursor is not None:
            import base64

            try:
                decoded = json.loads(
                    base64.urlsafe_b64decode(cursor.encode()).decode()
                )
                if decoded["user_id"] != user_id:
                    raise ValueError
                start = next(
                    i + 1 for i, item in enumerate(items)
                    if item["id"] == decoded["last_id"]
                )
            except Exception:
                raise ApiError(400, "invalid_cursor", "Invalid or expired cursor")

        page = items[start:start + limit]
        next_cursor = None

        if start + limit < len(items) and page:
            import base64

            payload = json.dumps({
                "user_id": user_id,
                "last_id": page[-1]["id"],
            }).encode()
            next_cursor = base64.urlsafe_b64encode(payload).decode()

        return {
            "items": page,
            "next_cursor": next_cursor,
        }


    def sync(self, user, cursor=None, limit=20):
        user_id = self._user_id(user)
        start = 0

        if cursor is not None:
            import base64

            try:
                decoded = json.loads(
                    base64.urlsafe_b64decode(cursor.encode()).decode()
                )
                if decoded["user_id"] != user_id:
                    raise ValueError
                start = int(decoded["sequence"])
            except Exception:
                raise ApiError(400, "invalid_cursor", "Invalid or expired cursor")

        events = [
            event for event in self.sync_events
            if event.get("user_id", user_id) == user_id
            and int(event["sequence"]) > start
        ]

        page = events[:limit]
        has_more = len(events) > limit

        # ?대깽?멸? ?녾굅??留덉?留??섏씠吏?щ룄 ?ъ슜?먮퀎 而ㅼ꽌瑜?諛섑솚?쒕떎.
        next_sequence = page[-1]["sequence"] if page else start

        import base64

        payload = json.dumps({
            "user_id": user_id,
            "sequence": next_sequence,
        }).encode()

        next_cursor = base64.urlsafe_b64encode(payload).decode()

        return {
            "events": [
                {
                    key: value
                    for key, value in event.items()
                    if key != "user_id"
                }
                for event in page
            ],
            "next_cursor": next_cursor,
            "has_more": has_more,
        }


repository = PostgresRepository()
