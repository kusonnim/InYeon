import asyncio
import hashlib
import json
import re
from dataclasses import dataclass
from io import BytesIO

import httpx
from PIL import Image

from app.config import Settings
from app.errors import ApiError
from app.models import MAX_ASSET_BYTES


BUCKET = "content-assets"
UPLOAD_TTL_SECONDS = 2 * 60 * 60
DOWNLOAD_TTL_SECONDS = 60
STORAGE_TIMEOUT = 25
MAX_IMAGE_PIXELS = 40_000_000
IMAGE_FORMATS = {"image/jpeg": "JPEG", "image/png": "PNG", "image/webp": "WEBP"}


@dataclass(frozen=True)
class AssetObject:
    object_path: str
    media_type: str
    size_bytes: int
    sha256: str


def _unavailable() -> ApiError:
    return ApiError(503, "storage_unavailable", "Private storage is temporarily unavailable")


def _oversized() -> ApiError:
    return ApiError(413, "asset_too_large", "Asset exceeds the 20 MiB limit")


def _invalid_bytes() -> ApiError:
    return ApiError(415, "invalid_media_type", "Uploaded bytes do not match the reserved media type")


def _verify_bytes(asset: AssetObject, data: bytes) -> None:
    if len(data) != asset.size_bytes:
        raise ApiError(422, "asset_size_mismatch", "Uploaded size differs from the reservation")
    if hashlib.sha256(data).hexdigest() != asset.sha256:
        raise ApiError(422, "asset_checksum_mismatch", "Uploaded checksum differs from the reservation")

    image_format = IMAGE_FORMATS.get(asset.media_type)
    if image_format:
        try:
            with Image.open(BytesIO(data), formats=[image_format]) as image:
                if image.width * image.height > MAX_IMAGE_PIXELS:
                    raise ApiError(413, "image_too_large", "Image exceeds the safe decoding dimensions")
                image.verify()
            # verify() alone does not decode every supported image format.
            with Image.open(BytesIO(data), formats=[image_format]) as image:
                image.load()
        except (OSError, ValueError, SyntaxError, Image.DecompressionBombError):
            raise _invalid_bytes() from None
    elif asset.media_type == "application/pdf":
        if not re.match(rb"%PDF-[12]\.\d(?:\r|\n)", data) or not data.rstrip().endswith(b"%%EOF"):
            raise _invalid_bytes()
    elif asset.media_type == "text/plain":
        try:
            text = data.decode("utf-8-sig")
        except UnicodeDecodeError:
            raise _invalid_bytes() from None
        if re.search(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]", text):
            raise _invalid_bytes()
    else:
        raise _invalid_bytes()


class SupabaseStorage:
    def __init__(self, settings: Settings):
        self._settings = settings
        self._verification_slots = asyncio.Semaphore(2)

    @property
    def configured(self) -> bool:
        return bool(self._settings.supabase_url and self._settings.supabase_service_role_key.get_secret_value())

    def _client(self) -> httpx.AsyncClient:
        if not self.configured:
            raise ApiError(503, "storage_unavailable", "Private storage is not configured")
        try:
            origin = httpx.URL(self._settings.supabase_url)
        except (httpx.InvalidURL, ValueError):
            raise _unavailable() from None
        local_http = (
            origin.scheme == "http" and origin.host in {"localhost", "127.0.0.1", "::1"}
            and self._settings.environment in {"local", "test"}
        )
        if (
            not origin.host or (origin.scheme != "https" and not local_http)
            or origin.path != "/" or origin.query or origin.fragment or origin.userinfo
        ):
            raise _unavailable()
        key = self._settings.supabase_service_role_key.get_secret_value()
        headers = {"apikey": key, "Accept-Encoding": "identity"}
        if not key.startswith("sb_secret_"):
            headers["Authorization"] = f"Bearer {key}"
        return httpx.AsyncClient(
            base_url=origin.copy_with(path="/storage/v1/"), headers=headers,
            timeout=httpx.Timeout(10, connect=4), follow_redirects=False, trust_env=False,
        )

    async def _sign(self, path: str, field: str, payload: dict, headers: dict | None = None) -> str:
        try:
            async with asyncio.timeout(STORAGE_TIMEOUT), self._client() as client:
                response = await client.post(path, json=payload, headers=headers)
                response.raise_for_status()
                signed = httpx.URL(response.json()[field])
                if (
                    not signed.is_relative_url or signed.host
                    or signed.raw_path.partition(b"?")[0] != f"/{path}".encode("ascii")
                    or signed.fragment or len(signed.params.multi_items()) != 1 or not signed.params.get("token")
                ):
                    raise _unavailable()
                return str(client.base_url.join(str(signed).lstrip("/")))
        except (httpx.HTTPError, httpx.InvalidURL, KeyError, ValueError, TypeError, TimeoutError):
            raise _unavailable() from None

    async def sign_upload(self, object_path: str) -> str:
        return await self._sign(
            f"object/upload/sign/{BUCKET}/{object_path}", "url", {}, {"x-upsert": "false"}
        )

    async def sign_download(self, object_path: str) -> str:
        return await self._sign(
            f"object/sign/{BUCKET}/{object_path}", "signedURL", {"expiresIn": DOWNLOAD_TTL_SECONDS}
        )

    async def read_verified(self, asset: AssetObject) -> bytes:
        async with self._verification_slots:
            data = await self._read(asset)
            await asyncio.to_thread(_verify_bytes, asset, data)
            return data

    async def _read(self, asset: AssetObject) -> bytes:
        try:
            async with asyncio.timeout(STORAGE_TIMEOUT), self._client() as client:
                async with client.stream("GET", f"object/authenticated/{BUCKET}/{asset.object_path}") as response:
                    if response.status_code == 404 or (
                        response.status_code == 400 and await _object_missing(response)
                    ):
                        raise ApiError(409, "upload_incomplete", "The reserved object has not been uploaded")
                    if response.status_code != 200:
                        raise _unavailable()
                    if response.headers.get("content-encoding", "identity").lower() != "identity":
                        raise _unavailable()
                    media_type = response.headers.get("content-type", "").split(";", 1)[0].strip().lower()
                    if media_type != asset.media_type:
                        raise _invalid_bytes()
                    size = response.headers.get("content-length")
                    if size is not None:
                        actual_size = int(size)
                        if actual_size > MAX_ASSET_BYTES:
                            raise _oversized()
                        if actual_size != asset.size_bytes:
                            raise ApiError(422, "asset_size_mismatch", "Uploaded size differs from the reservation")
                    data = bytearray()
                    async for chunk in response.aiter_raw(chunk_size=65536):
                        received_size = len(data) + len(chunk)
                        if received_size > MAX_ASSET_BYTES:
                            raise _oversized()
                        if received_size > asset.size_bytes:
                            raise ApiError(422, "asset_size_mismatch", "Uploaded size differs from the reservation")
                        data.extend(chunk)
                    return bytes(data)
        except (httpx.HTTPError, TimeoutError, ValueError):
            raise _unavailable() from None


async def _object_missing(response: httpx.Response) -> bool:
    payload = bytearray()
    async for chunk in response.aiter_raw(chunk_size=4096):
        if len(payload) + len(chunk) > 4096:
            return False
        payload.extend(chunk)
    try:
        error = json.loads(payload)
        return isinstance(error, dict) and str(error.get("statusCode")) == "404"
    except (ValueError, UnicodeError):
        return False
