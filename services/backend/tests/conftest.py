import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app


@pytest.fixture
def client():
    with TestClient(create_app(Settings(mode="fixture", environment="test"))) as test_client:
        yield test_client


@pytest.fixture
def auth():
    return {"Authorization": "Bearer fixture-user-a"}
