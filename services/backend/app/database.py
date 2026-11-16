from typing import AsyncGenerator
from uuid import UUID

from asyncpg import PostgresError
from fastapi import Request
from sqlalchemy import text
from sqlalchemy.engine import make_url
from sqlalchemy.exc import ArgumentError, DBAPIError, TimeoutError as PoolTimeoutError
from sqlalchemy.ext.asyncio import (
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from app.errors import ApiError


def create_database_engine(database_url: str):
    if not database_url:
        raise ValueError("DATABASE_URL is not configured")

    url = make_url(database_url)

    if url.drivername in ("postgresql", "postgres"):
        url = url.set(drivername="postgresql+asyncpg")

    if url.drivername != "postgresql+asyncpg":
        raise ValueError(
            "DATABASE_URL must use PostgreSQL with asyncpg"
        )

    query = dict(url.query)
    sslmode = query.pop("sslmode", None)

    if sslmode and "ssl" not in query:
        query["ssl"] = sslmode

    url = url.set(query=query)

    return create_async_engine(
        url,
        echo=False,
        hide_parameters=True,
        pool_pre_ping=True,
        pool_size=5,
        max_overflow=10,
        connect_args={"timeout": 5},
    )


async def lock_owner_sync(db: AsyncSession, user_id: str | UUID) -> None:
    await db.execute(
        text("SELECT public.lock_sync_head(CAST(:user_id AS uuid))"),
        {"user_id": user_id},
    )


async def append_sync_event(
    db: AsyncSession,
    user_id: str | UUID,
    entity_type: str,
    entity_id: str | UUID,
    content_id: str | UUID | None = None,
) -> None:
    await db.execute(
        text("""
            SELECT public.append_sync_event(
                CAST(:user_id AS uuid), :entity_type, CAST(:entity_id AS uuid),
                'upsert', CAST(:content_id AS uuid)
            )
        """),
        {
            "user_id": user_id,
            "entity_type": entity_type,
            "entity_id": entity_id,
            "content_id": content_id,
        },
    )


def configure_database(app, settings):
    app.state.engine = None
    app.state.db_session_factory = None
    app.state.database_url = settings.database_url


async def get_db(request: Request) -> AsyncGenerator[AsyncSession | None, None]:
    app = request.app
    app_settings = app.state.settings

    if app_settings.mode == "fixture":
        yield None
        return

    session_factory = app.state.db_session_factory

    if session_factory is None:
        try:
            engine = create_database_engine(app.state.database_url)
            session_factory = async_sessionmaker(
                bind=engine,
                class_=AsyncSession,
                expire_on_commit=False,
                autoflush=False,
            )
            app.state.engine = engine
            app.state.db_session_factory = session_factory
        except (ArgumentError, ValueError):
            raise ApiError(503, "database_unavailable", "Database connection is not configured") from None

    try:
        async with session_factory() as session:
            yield session
    except (OSError, PoolTimeoutError):
        raise ApiError(503, "database_unavailable", "Database connection is temporarily unavailable") from None
    except (DBAPIError, PostgresError) as exc:
        original = exc.orig if isinstance(exc, DBAPIError) else exc
        state = getattr(original, "sqlstate", None) or ""
        if getattr(exc, "connection_invalidated", False) or state.startswith(("08", "28")) or state in {
            "3D000", "53300", "57P01", "57P02", "57P03",
        }:
            raise ApiError(503, "database_unavailable", "Database connection is temporarily unavailable") from None
        raise

def create_worker_session_factory():
    from app.config import get_settings

    settings = get_settings()

    if settings.mode == "fixture":
        raise RuntimeError(
            "Worker cannot run in fixture mode."
        )

    engine = create_database_engine(settings.database_url)

    return (
        engine,
        async_sessionmaker(
            bind=engine,
            class_=AsyncSession,
            expire_on_commit=False,
            autoflush=False,
        ),
    )
async def close_database(app):
    engine = app.state.engine

    if engine is not None:
        await engine.dispose()
        app.state.engine = None
        app.state.db_session_factory = None
