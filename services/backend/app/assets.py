import hashlib
import json
from datetime import datetime, timedelta, timezone
from uuid import UUID, uuid4

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import ApiError
from app.models import AssetComplete, AssetDownload, AssetUpload, AssetUploadCreate
from app.repository import repository
from app.storage import AssetObject, DOWNLOAD_TTL_SECONDS, UPLOAD_TTL_SECONDS, SupabaseStorage


UPLOAD_OPERATION = "create-asset-upload"


def _expired() -> ApiError:
    return ApiError(409, "upload_expired", "Upload reservation expired; use a new idempotency key")


async def reserve_upload(
    db: AsyncSession, storage: SupabaseStorage, user_id: str, key: str, value: AssetUploadCreate,
) -> AssetUpload:
    payload = value.model_dump(mode="json")
    digest = hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    async with db.begin():
        # A replay of the same key must observe the committed reservation even with concurrent requests.
        # Keep this lock separate from the owner sync lock while requesting a Storage capability.
        await db.execute(
            text("SELECT pg_advisory_xact_lock(hashtextextended(:scope, 0))"),
            {"scope": f"itda:{UPLOAD_OPERATION}:{user_id}:{key}"},
        )
        existing = await repository.get_idempotency(
            db=db, idempotency_key=key, user_id=user_id, operation=UPLOAD_OPERATION,
        )
        if existing:
            if existing["request_hash"] != digest:
                raise ApiError(409, "idempotency_conflict", "The idempotency key was already used with a different request")
            replay = AssetUpload.model_validate(existing["response_body"])
            if replay.expires_at <= datetime.now(timezone.utc):
                raise _expired()
            return replay

        asset_id = uuid4()
        path = f"{user_id}/{asset_id}/source"
        expires_at = datetime.now(timezone.utc) + timedelta(seconds=UPLOAD_TTL_SECONDS)
        await db.execute(
            text("""
                INSERT INTO public.content_assets (
                    id, user_id, filename, media_type, size_bytes, sha256, object_path, upload_expires_at
                )
                VALUES (
                    :id, :user_id, :filename, :media_type, :size_bytes, :sha256, :object_path, :expires_at
                )
            """),
            {**payload, "id": asset_id, "user_id": user_id, "object_path": path, "expires_at": expires_at},
        )
        capability = AssetUpload(
            asset_id=asset_id,
            upload_url=await storage.sign_upload(path),
            upload_headers={"Content-Type": value.media_type, "x-upsert": "false"},
            expires_at=expires_at,
        )
        await db.execute(
            text("""
                INSERT INTO public.idempotency_records (
                    user_id, operation, idempotency_key, request_hash, response_status, response_body
                )
                VALUES (:user_id, :operation, :key, :digest, 201, CAST(:body AS jsonb))
            """),
            {
                "user_id": user_id, "operation": UPLOAD_OPERATION, "key": key, "digest": digest,
                "body": capability.model_dump_json(),
            },
        )
    return capability


async def _owned_asset(db: AsyncSession, user_id: str, asset_id: UUID, *, lock: bool = False):
    statement = """
        SELECT id, object_path, media_type, size_bytes, sha256, status,
               upload_expires_at <= clock_timestamp() AS expired
        FROM public.content_assets
        WHERE user_id = :user_id AND id = :id
    """
    result = await db.execute(
        text(statement + (" FOR UPDATE" if lock else "")), {"user_id": user_id, "id": asset_id},
    )
    asset = result.mappings().one_or_none()
    if asset is None:
        raise ApiError(404, "not_found", "Asset not found")
    return asset


def _completion(asset) -> AssetComplete:
    return AssetComplete(
        asset_id=asset["id"], status="ready", media_type=asset["media_type"],
        size_bytes=asset["size_bytes"], sha256=asset["sha256"],
    )


async def complete_upload(
    db: AsyncSession, storage: SupabaseStorage, user_id: str, asset_id: UUID,
) -> AssetComplete:
    async with db.begin():
        asset = await _owned_asset(db, user_id, asset_id)
        if asset["status"] == "ready":
            return _completion(asset)
        if asset["expired"]:
            raise _expired()

    await storage.read_verified(AssetObject(
        asset["object_path"], asset["media_type"], asset["size_bytes"], asset["sha256"],
    ))

    async with db.begin():
        # Client capabilities cannot replace the object. Concurrent completion may already have marked it ready.
        asset = await _owned_asset(db, user_id, asset_id, lock=True)
        if asset["status"] == "ready":
            return _completion(asset)
        if asset["expired"]:
            raise _expired()
        await db.execute(
            text("""
                UPDATE public.content_assets
                SET status = 'ready', verified_at = clock_timestamp()
                WHERE id = :id AND user_id = :user_id
            """),
            {"id": asset_id, "user_id": user_id},
        )
    return _completion(asset)


async def download_url(
    db: AsyncSession, storage: SupabaseStorage, user_id: str, asset_id: UUID,
) -> AssetDownload:
    async with db.begin():
        asset = await _owned_asset(db, user_id, asset_id)
        if asset["status"] != "ready":
            raise ApiError(404, "not_found", "Asset not found")

    expires_at = datetime.now(timezone.utc) + timedelta(seconds=DOWNLOAD_TTL_SECONDS)
    return AssetDownload(
        asset_id=asset_id, download_url=await storage.sign_download(asset["object_path"]), expires_at=expires_at,
    )
