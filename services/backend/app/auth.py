import asyncio
from functools import lru_cache
from typing import Annotated
from uuid import UUID

import jwt
from fastapi import Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jwt import PyJWKClient
from jwt.exceptions import InvalidTokenError, PyJWKClientConnectionError, PyJWKClientError

from app.config import get_settings
from app.errors import ApiError


security = HTTPBearer(
    auto_error=False,
    scheme_name="BearerAuth",
    description="Supabase access JWT in production. Explicit local fixture mode only: fixture-user-a/b.",
)
ALLOWED_ASYMMETRIC_ALGORITHMS = {"RS256", "ES256", "EdDSA"}


@lru_cache(maxsize=8)
def jwks_client(url: str) -> PyJWKClient:
    return PyJWKClient(url, timeout=5)


async def get_current_user_id(
    request: Request,
    credentials: HTTPAuthorizationCredentials | None = Depends(security),
) -> str:
    settings = getattr(request.app.state, "settings", None) or get_settings()
    if settings.mode == "fixture":
        if credentials is None:
            return "fixture-user-a"
        if not credentials.credentials.startswith("fixture-user-"):
            raise ApiError(401, "unauthorized", "Invalid fixture token")
        return credentials.credentials

    if credentials is None or credentials.credentials.startswith("fixture-user-"):
        raise ApiError(401, "unauthorized", "A valid bearer access token is required")
    if not (settings.supabase_jwks_url or settings.supabase_jwt_secret):
        raise ApiError(501, "adapter_not_implemented", "Authentication verification is not configured")
    if not settings.supabase_jwt_issuer:
        raise ApiError(503, "auth_unavailable", "Authentication issuer is not configured")

    token = credentials.credentials
    try:
        algorithm = jwt.get_unverified_header(token).get("alg")
        if not isinstance(algorithm, str) or (
            settings.supabase_jwt_algorithm and algorithm != settings.supabase_jwt_algorithm
        ):
            raise InvalidTokenError("Unexpected JWT signing algorithm")

        if settings.supabase_jwks_url and algorithm in ALLOWED_ASYMMETRIC_ALGORITHMS:
            client = jwks_client(settings.supabase_jwks_url)
            key = (await asyncio.to_thread(client.get_signing_key_from_jwt, token)).key
        elif not settings.supabase_jwks_url and settings.supabase_jwt_secret and algorithm == "HS256":
            key = settings.supabase_jwt_secret
        else:
            raise InvalidTokenError("Unsupported JWT signing algorithm")

        payload = jwt.decode(
            token,
            key,
            algorithms=[algorithm],
            issuer=settings.supabase_jwt_issuer,
            audience="authenticated",
            options={"require": ["exp", "sub"]},
            leeway=30,
        )
        return str(UUID(payload["sub"]))
    except PyJWKClientConnectionError:
        raise ApiError(503, "auth_unavailable", "Authentication keys are temporarily unavailable") from None
    except (InvalidTokenError, PyJWKClientError, ValueError, TypeError, AttributeError):
        raise ApiError(401, "unauthorized", "Invalid access token") from None


User = Annotated[str, Depends(get_current_user_id)]
