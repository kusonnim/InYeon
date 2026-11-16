from typing import Annotated, Optional
from uuid import UUID
from fastapi import APIRouter, Header, Query, Request, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession
from app.auth import User
from app.database import get_db
from app.errors import ApiError
from app.repository import repository
from app.models import (
    AssetComplete, AssetDownload, AssetUpload, AssetUploadCreate,
    Content, ContentCreate, ContentPage, ContentPatch, ErrorResponse,
    FeedbackCreate, FeedbackEvent, NotificationEvent, NotificationRestore,
    NotificationResult, Preferences, PreferencesPatch, Recommendation,
    RecommendationPatch, SyncPage
)

ERRORS = {
    code: {"model": ErrorResponse, "description": text}
    for code, text in {
        400: "Invalid or expired cursor",
        401: "Missing or invalid bearer access token",
        404: "Not found, including resources belonging to another user",
        409: "Version, notification generation/revision, or idempotency conflict",
        413: "Asset exceeds size limit",
        415: "Unsupported media type",
        422: "Request validation failed",
        501: "Adapter not implemented in this scaffold",
        503: "Temporary upstream failure; retry with the same idempotency key",
    }.items()
}

# main.py에서 include_router(..., prefix="/v1")로 등록되므로 라우터 자체 prefix는 생략합니다.
router = APIRouter(responses=ERRORS)
Key = Annotated[
    str,
    Header(
        alias="Idempotency-Key",
        min_length=8,
        max_length=128,
        description="Stable client-generated key per logical operation; retain across retries."
    )
]
Limit = Annotated[
    int,
    Query(ge=1, le=100, description="Maximum items; default 20.")
]
Cursor = Annotated[
    Optional[str],
    Query(max_length=2048, description="Opaque account-bound cursor; never construct or modify.")
]

@router.post(
    "/contents",
    response_model=Content,
    status_code=201,
    tags=["contents"],
    operation_id="createContent",
    summary="Durably receive content and schedule analysis",
    description=(
        "Production contract: atomically persist source references, owned ready assets, "
        "one job, initial notification state and sync event before 201. Never await AI. "
        "Same user + operation + Idempotency-Key and payload returns the original 201; "
        "changed payload returns 409. Fixture mode simulates this in volatile memory "
        "and is NOT a durable receipt."
    )
)
async def create_content(
    value: ContentCreate,
    user: User,
    request: Request,
    key: Key,
    db: AsyncSession = Depends(get_db)
):
    if hasattr(request.app.state, "settings") and getattr(request.app.state.settings, "mode", None) == "fixture":
        rep = request.app.state.repository
        return rep.once(user, "create-content", key, value.model_dump(mode="json"), lambda: rep.create(user, value))

    return await repository.create_content(
        db=db,
        user_id=user,
        idempotency_key=key,
        content_data=value.model_dump(mode="json"),
    )
@router.get(
    "/contents",
    response_model=ContentPage,
    tags=["contents"],
    operation_id="listContents",
    description=(
        "Owner-only keyset pagination, newest created_at then id descending. "
        "New inserts before the cursor are obtained through sync or a fresh list. "
        "Dismissed and archived items remain in the library."
    )
)
async def list_contents(
    user: User,
    request: Request,
    cursor: Cursor = None,
    limit: Limit = 20,
    db: AsyncSession = Depends(get_db)
):
    if hasattr(request.app.state, "settings") and getattr(request.app.state.settings, "mode", None) == "fixture":
        return request.app.state.repository.list_contents(user, cursor, limit)

    return await repository.list_contents(
        db=db,
        user_id=user,
        limit=limit,
        cursor=cursor,
    )
@router.get(
    "/contents/{id}",
    response_model=Content,
    tags=["contents"],
    operation_id="getContent"
)
async def get_content(
    id: UUID,
    user: User,
    request: Request,
    db: AsyncSession = Depends(get_db)
):
    if hasattr(request.app.state, "settings") and getattr(request.app.state.settings, "mode", None) == "fixture":
        return request.app.state.repository.owned(user, id)

    content = await repository.get_content(db=db, content_id=str(id), user_id=user)
    if not content:
        raise HTTPException(status_code=404, detail="Not found")
    return content


@router.patch(
    "/contents/{id}",
    response_model=Content,
    tags=["contents"],
    operation_id="updateContent",
    description=(
        "Compare expected_version atomically; 409 includes current_version. "
        "Omitted editable fields are preserved; explicit null clears title/user_note. "
        "Sources and AI output are immutable through this endpoint. "
        "Workflow edits never change notification visibility."
    ),
)
async def update_content(
    id: UUID,
    value: ContentPatch,
    user: User,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    if request.app.state.repository is not None:
        return request.app.state.repository.patch_content(user, id, value)

    return await repository.patch_content(
        db=db,
        user_id=str(user),
        content_id=str(id),
        value=value,
    )

@router.patch(
    "/recommendations/{id}",
    response_model=Recommendation,
    tags=["recommendations"],
    operation_id="updateRecommendation",
    description=(
        "Keep AI text and user_text separate. accepted changes are explicit feedback, "
        "never inferred from generation or notification dismissal. Compare expected_version; "
        "update the parent content version and sync event atomically. "
        "Omitted fields preserved; null clears user_text."
    )
)
async def update_recommendation(
    id: UUID,
    value: RecommendationPatch,
    user: User,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    if request.app.state.repository is not None:
        return request.app.state.repository.patch_recommendation(
            user, id, value
        )

    return await repository.patch_recommendation(
        db=db,
        user_id=str(user),
        recommendation_id=str(id),
        value=value,
    )

@router.post(
    "/feedback",
    response_model=FeedbackEvent,
    status_code=201,
    tags=["feedback"],
    operation_id="createFeedback",
    description=(
        "Append explicit feedback without changing workflow or notification state. "
        "This event records feedback only; use recommendation PATCH to edit its accepted flag. "
        "Owner and content/recommendation relationship are checked."
    )
)

async def create_feedback(
    value: FeedbackCreate,
    user: User,
    key: Key,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    if request.app.state.repository is not None:
        rep = request.app.state.repository
        return rep.once(
            user,
            "feedback",
            key,
            value.model_dump(mode="json"),
            lambda: rep.add_feedback(user, value),
        )

    return await repository.create_feedback(
        db=db,
        user_id=str(user),
        idempotency_key=key,
        feedback_data=value.model_dump(mode="json"),
    )


@router.get(
    "/preferences",
    response_model=Preferences,
    tags=["preferences"],
    operation_id="getPreferences",
)
async def get_preferences(
    user: User,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    if request.app.state.repository is not None:
        return request.app.state.repository.get_preferences(user)

    return await repository.get_preferences(
        db=db,
        user_id=str(user),
    )


@router.patch(
    "/preferences",
    response_model=Preferences,
    tags=["preferences"],
    operation_id="updatePreferences",
    description=(
        "Explicit preferences/behavior outweigh optional MBTI. "
        "Omitted fields preserved; null clears mbti; arrays cannot be null. "
        "Compare expected_version."
    ),
)
async def update_preferences(
    value: PreferencesPatch,
    user: User,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    if request.app.state.repository is not None:
        return request.app.state.repository.patch_preferences(user, value)

    return await repository.patch_preferences(
        db=db,
        user_id=str(user),
        value=value,
    )

@router.post(
    "/notification-events",
    response_model=NotificationResult,
    tags=["notifications"],
    operation_id="recordNotificationEvent",
    description=(
        "Only dismissal is supported. A smaller generation is acknowledged as "
        "stale_generation without applying it. Matching generation with wrong revision "
        "or future generation returns 409. Matching already-dismissed state is a no-op. "
        "Never changes workflow. Retry offline events with the original Idempotency-Key."
    )
)
async def notification_event(
    value: NotificationEvent,
    user: User,
    key: Key,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    if request.app.state.repository is not None:
        rep = request.app.state.repository
        return rep.once(
            user,
            "notification-event",
            key,
            value.model_dump(mode="json"),
            lambda: rep.notification_event(user, value),
        )

    return await repository.notification_event(
        db=db,
        user_id=str(user),
        idempotency_key=key,
        event_data=value.model_dump(mode="json"),
    )
@router.post(
    "/contents/{id}/notification/restore",
    response_model=NotificationResult,
    tags=["notifications"],
    operation_id="restoreNotification",
    description=(
        "Explicit user restoration only. Compare generation AND revision. "
        "Dismissed -&gt; active increments both generation and revision; active with matching "
        "versions is already_active no-op. Replay same idempotency key returns original response. "
        "This is the only transition that restores dismissed visibility."
    )
)
async def restore_notification(
    id: UUID,
    value: NotificationRestore,
    user: User,
    key: Key,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    if request.app.state.repository is not None:
        rep = request.app.state.repository
        return rep.once(
            user,
            f"restore:{id}",
            key,
            value.model_dump(mode="json"),
            lambda: rep.restore(user, id, value),
        )

    return await repository.restore_notification(
        db=db,
        user_id=str(user),
        content_id=str(id),
        idempotency_key=key,
        restore_data=value.model_dump(mode="json"),
    )

@router.get(
    "/sync",
    response_model=SyncPage,
    tags=["sync"],
    operation_id="syncChanges",
    description=(
        "Owner-scoped commit-ordered changes. No cursor starts from retained beginning. "
        "Consume pages until has_more=false, persist next_cursor only after applying events; "
        "refresh GET /contents/{content_id} for content/recommendation/notification events "
        "and GET /preferences for preference events. content_id is null only for preferences. "
        "Delete events are tombstones; remove the matching local entity. Repeated cursors "
        "replay events; deduplicate by sequence. Invalid/expired cursor -&gt;400 invalid_cursor "
        "and full bootstrap. Sequence is decimal string to avoid JavaScript precision loss. "
        "Production cursor retention/expiry is unresolved; fixture cursors expire on process restart."
    )
)
def sync_changes(user: User, request: Request, cursor: Cursor = None, limit: Limit = 20):
    return request.app.state.repository.sync(user, cursor, limit)

@router.post(
    "/assets/uploads",
    response_model=AssetUpload,
    status_code=201,
    tags=["assets"],
    operation_id="createAssetUpload",
    description=(
        "Reserve private content-assets/{authenticated_user_id}/{asset_id}/source. "
        "Server generates path and signed PUT/upload capability with upsert=false; "
        "never accept client paths or user IDs. Signed upload capability currently "
        "has Supabase's 2-hour lifetime; expiry is explicit. Allow JPEG/PNG/WebP/PDF/plain text, &lt;=20 MiB. "
        "Do not log capability URLs. Replays return same reservation while live; "
        "expired reservation -&gt;409 upload_expired, use a new key. Phase 0 returns 501; no fake upload URL."
    )
)
def create_asset_upload(value: AssetUploadCreate, user: User, key: Key):
    raise ApiError(501, "adapter_not_implemented", "Private storage upload adapter is not implemented")

@router.post(
    "/assets/{id}/complete",
    response_model=AssetComplete,
    tags=["assets"],
    operation_id="completeAssetUpload",
    description=(
        "Owner-only verification of the exact reserved object's existence, actual bytes, "
        "signature/media type, size and SHA-256; reject mismatch. Mark ready only after server verification. "
        "Idempotent completion before content ingestion. Unclaimed uploads expire and are "
        "garbage-collected by a planned service job. Attach each ready asset once to owned content in its ingestion transaction."
    )
)
def complete_asset_upload(id: UUID, user: User, key: Key):
    raise ApiError(501, "adapter_not_implemented", "Private storage verification adapter is not implemented")

@router.get(
    "/assets/{id}/download-url",
    response_model=AssetDownload,
    tags=["assets"],
    operation_id="getAssetDownloadUrl",
    description=(
        "Owner-only short-lived (at most 60 seconds) signed GET for a verified ready asset. "
        "Objects and bucket remain private. Bearer capability URL must never be stored in source_url, "
        "sync events, analytics, or logs. Set Cache-Control: no-store. Phase 0 returns 501."
    )
)
def get_asset_download_url(id: UUID, user: User):
    raise ApiError(501, "adapter_not_implemented", "Private storage download adapter is not implemented")