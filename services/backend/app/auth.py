from typing import Annotated
from uuid import UUID

from fastapi import Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.errors import ApiError

bearer = HTTPBearer(auto_error=False, scheme_name="BearerAuth",
                    description="Supabase access JWT in production. Explicit local fixture mode only: fixture-user-a/b.")
FIXTURE_USERS = {
    "fixture-user-a": UUID("00000000-0000-4000-8000-000000000001"),
    "fixture-user-b": UUID("00000000-0000-4000-8000-000000000002"),
}


def current_user(request: Request,
                 credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)]) -> UUID:
    if not credentials or credentials.scheme.lower() != "bearer":
        raise ApiError(401, "unauthorized", "A bearer access token is required")
    if request.app.state.settings.mode != "fixture":
        # JWT signature/issuer/audience/expiry validation is intentionally not implemented yet.
        # Never decode an unverified token or trust a client-supplied user_id.
        raise ApiError(501, "adapter_not_implemented", "Production authentication and persistence adapters are not implemented")
    user = FIXTURE_USERS.get(credentials.credentials)
    if not user:
        raise ApiError(401, "unauthorized", "Invalid fixture token")
    return user


User = Annotated[UUID, Depends(current_user)]

