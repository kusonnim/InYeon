import asyncio
import logging
from typing import Optional
from uuid import UUID
from typing import Annotated, Optional

import jwt
from jwt import PyJWKClient
from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials

from app.config import Settings, get_settings


logger = logging.getLogger(__name__)

security = HTTPBearer(
    auto_error=False,
    scheme_name="BearerAuth",
    description="Supabase access JWT in production. Explicit local fixture mode only: fixture-user-a/b.",
)
# Supabase 비대칭 서명에서 허용할 알고리즘
ALLOWED_ASYMMETRIC_ALGORITHMS = {
    "RS256",
    "ES256",
    "EdDSA",
}


def get_app_settings(request: Request) -> Settings:
    return getattr(
        request.app.state,
        "settings",
        get_settings(),
    )


async def get_current_user_id(
    request: Request,
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(security),
) -> str:

    settings = get_app_settings(request)

    # 1. Fixture 인증
    if settings.mode == "fixture":
        if credentials is None:
            return "fixture-user-a"

        token = credentials.credentials

        if not token.startswith("fixture-user-"):
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Invalid fixture token.",
            )

        return token

    # 2. Production 인증 헤더 확인
    if credentials is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Bearer token is required.",
        )

    token = credentials.credentials

    # Production에서는 Fixture 토큰 사용 금지
    if token.startswith("fixture-user-"):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Fixture tokens are not allowed in production.",
        )

        # JWT 검증 수단이 하나도 설정되지 않은 경우
    if not settings.supabase_jwks_url and not settings.supabase_jwt_secret:
        logger.error("No Supabase JWT verification method configured.")
        raise HTTPException(
            status_code=status.HTTP_501_NOT_IMPLEMENTED,
            detail="Authentication verification is not implemented.",
        )

    issuer = settings.supabase_jwt_issuer

    if not issuer:
        logger.error("Supabase JWT issuer is not configured.")
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Authentication is not configured.",
        )
    try:
        # 3. JWT 헤더 확인
        unverified_header = jwt.get_unverified_header(token)
        algorithm = unverified_header.get("alg")

        configured_algorithm = settings.supabase_jwt_algorithm

        if configured_algorithm and algorithm != configured_algorithm:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Unexpected JWT signing algorithm.",
            )

        # 4. JWKS 비대칭 서명 검증
        if settings.supabase_jwks_url:
            if algorithm not in ALLOWED_ASYMMETRIC_ALGORITHMS:
                raise HTTPException(
                    status_code=status.HTTP_401_UNAUTHORIZED,
                    detail="Unsupported JWT signing algorithm.",
                )

            jwks_client = PyJWKClient(
                settings.supabase_jwks_url,
                cache_keys=True,
            )

            signing_key = await asyncio.to_thread(
                jwks_client.get_signing_key_from_jwt,
                token,
            )

            payload = jwt.decode(
                token,
                signing_key.key,
                algorithms=[algorithm],
                issuer=issuer,
                audience="authenticated",
                options={
                    "require": ["exp", "sub"],
                },
                leeway=30,
            )

        # 5. Legacy HS256 서명 검증
        elif (
            algorithm == "HS256"
            and settings.supabase_jwt_secret
        ):
            payload = jwt.decode(
                token,
                settings.supabase_jwt_secret,
                algorithms=["HS256"],
                issuer=issuer,
                audience="authenticated",
                options={
                    "require": ["exp", "sub"],
                },
                leeway=30,
            )

        else:
            logger.error("No valid Supabase JWT verification method configured.")
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="Authentication verification is not configured.",
            )

        # 6. Supabase 사용자 UUID 검증
        user_id = payload.get("sub")

        if not user_id:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="JWT subject is missing.",
            )

        try:
            return str(UUID(user_id))
        except (ValueError, TypeError, AttributeError):
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="JWT subject is not a valid user UUID.",
            )

    except HTTPException:
        raise

    except jwt.ExpiredSignatureError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Access token has expired.",
        )

    except jwt.InvalidTokenError:
        logger.warning("Supabase JWT verification failed.")
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid access token.",
        )

    except Exception:
        logger.exception("Unexpected error during JWT verification.")
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Authentication service is temporarily unavailable.",
        )
User = Annotated[str, Depends(get_current_user_id)]