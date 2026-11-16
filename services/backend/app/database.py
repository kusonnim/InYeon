from typing import AsyncGenerator

from fastapi import HTTPException, Request, status
from sqlalchemy.engine import make_url
from sqlalchemy.ext.asyncio import (
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)


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
        pool_pre_ping=True,
        pool_size=5,
        max_overflow=10,
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
        except Exception:
            raise HTTPException(
                status_code=503,
                detail="Database connection is not configured.",
            )

    async with session_factory() as session:
        yield session

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