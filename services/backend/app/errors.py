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
    return JSONResponse(ApiError(422, "validation_error", "Request does not match the contract").body,
                        status_code=422)

