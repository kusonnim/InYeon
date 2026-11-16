from uuid import uuid4

from fastapi import Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str, **details):
        self.status = status
        self.body = {"error": {"code": code, "message": message,
                               "request_id": str(uuid4()), **details}}


async def api_error_handler(request: Request, exc: ApiError):
    return JSONResponse(exc.body, status_code=exc.status)


async def validation_error_handler(request: Request, exc: RequestValidationError):
    # Never echo source content, bearer tokens, or uploaded data in error responses.
    if getattr(request.scope.get("route"), "operation_id", None) == "createAssetUpload":
        errors = {(error["loc"], error["type"]) for error in exc.errors()}
        if (("body", "size_bytes"), "less_than_equal") in errors:
            return await api_error_handler(
                request, ApiError(413, "asset_too_large", "Asset exceeds the 20 MiB limit"),
            )
        if (("body", "media_type"), "literal_error") in errors:
            return await api_error_handler(
                request, ApiError(415, "unsupported_media_type", "Media type is outside the upload allowlist"),
            )
    return JSONResponse(ApiError(422, "validation_error", "Request does not match the contract").body,
                        status_code=422)

