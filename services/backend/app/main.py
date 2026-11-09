from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError

from app.config import Settings, get_settings
from app.errors import ApiError, api_error_handler, validation_error_handler
from app.models import Health
from app.repository import FixtureRepository
from app.routers import router


def create_app(settings: Settings | None = None, *, seed: bool = True) -> FastAPI:
    settings = settings or get_settings()
    application = FastAPI(title="ITDA API", version="0.1.0",
        description="Phase 0 reviewed API contract. Bearer authentication required on all /v1 routes. UTC ISO 8601 timestamps, UUID identifiers, snake_case JSON. Structured errors never include source text or credentials. Production data adapters remain unimplemented; local fixture mode is volatile and must not be deployed.")
    application.state.settings = settings
    application.state.repository = FixtureRepository(seed=seed) if settings.mode == "fixture" else None
    application.add_exception_handler(ApiError, api_error_handler)
    application.add_exception_handler(RequestValidationError, validation_error_handler)

    @application.get("/health", response_model=Health, tags=["operations"], operation_id="health",
                     description="Process health only; not database, worker or deployment readiness.")
    def health():
        return {"status": "ok", "mode": settings.mode,
                "persistence": "volatile-memory" if settings.mode == "fixture" else "unconfigured"}

    application.include_router(router)
    return application


app = create_app()
