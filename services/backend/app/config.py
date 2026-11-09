from functools import lru_cache
from typing import Literal

from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="ITDA_", env_file=".env", extra="ignore")
    mode: Literal["production", "fixture"] = "production"
    environment: Literal["local", "test", "production"] = "local"
    supabase_url: str = ""
    supabase_service_role_key: str = ""
    llm_api_key: str = ""
    fcm_credentials_path: str = ""

    @model_validator(mode="after")
    def fixture_is_local(self):
        if self.mode == "fixture" and self.environment == "production":
            raise ValueError("Fixture mode must never be deployed")
        return self


@lru_cache
def get_settings() -> Settings:
    return Settings()
