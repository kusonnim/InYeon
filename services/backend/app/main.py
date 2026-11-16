from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError
from app.config import Settings, get_settings
from app.errors import ApiError, api_error_handler, validation_error_handler
from app.models import Health
from app.repository import FixtureRepository
from app.routers import router as contents_router
from app.storage import SupabaseStorage
from contextlib import asynccontextmanager
from app.database import configure_database, close_database

@asynccontextmanager
async def lifespan(application: FastAPI):
    try:
        yield
    finally:
        await close_database(application)

def create_app(
    settings: Settings | None = None,
    *,
    seed: bool = True,
) -> FastAPI:
    settings = settings or get_settings()

    application = FastAPI(
        title="ITDA API",
        version="0.1.0",
        lifespan=lifespan,
        description=(
            "Phase 0 reviewed API contract. "
            "Bearer authentication required on all /v1 routes. "
            "UTC ISO 8601 timestamps, UUID identifiers, snake_case JSON. "
            "Structured errors never include source text or credentials. "
            "Production content and sync use PostgreSQL. "
            "Local fixture mode is volatile and must not be deployed."
        ),
    )

    application.state.settings = settings
    application.state.storage = SupabaseStorage(settings)
    configure_database(application, settings)

    application.state.repository = (
        FixtureRepository(seed=seed)
        if settings.mode == "fixture"
        else None
    )


    application.add_exception_handler(
        ApiError,
        api_error_handler,
    )
    application.add_exception_handler(
        RequestValidationError,
        validation_error_handler,
    )

    @application.get(
        "/health",
        response_model=Health,
        tags=["operations"],
        operation_id="health",
        description=(
            "Reports process health and the configured persistence adapter. "
            "Use an authenticated API request to verify database connectivity."
        ),
    )
    def health():
        persistence = "unconfigured"
        if settings.mode == "fixture":
            persistence = "volatile-memory"
        elif settings.database_url:
            persistence = "postgresql"
        return {
            "status": "ok",
            "mode": settings.mode,
            "persistence": persistence,
        }

    # 테스트 계약에 맞춰 /v1 경로 사용
    application.include_router(
        contents_router,
        prefix="/v1",
    )
    original_openapi = application.openapi

    def custom_openapi():
        if application.openapi_schema is None:
            schema = original_openapi()

            for path_item in schema.get("paths", {}).values():
                for operation in path_item.values():
                    if isinstance(operation, dict):
                        description = operation.get("description")

                        if isinstance(description, str):
                            operation["description"] = (
                                description
                                .replace("&lt;", "<")
                                .replace("&gt;", ">")
                            )

            application.openapi_schema = schema

        return application.openapi_schema

    application.openapi = custom_openapi
    return application


app = create_app()
