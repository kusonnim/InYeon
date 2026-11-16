from functools import lru_cache
from typing import Literal

from pydantic import AliasChoices, Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="ITDA_",
        env_file=".env",
        extra="ignore",
    )

    mode: Literal["production", "fixture"] = "production"
    environment: Literal["local", "test", "production"] = "local"

    # PostgreSQL connection string
    # DATABASE_URL 또는 ITDA_DATABASE_URL 환경변수 사용
    database_url: str = Field(
        default="",
        validation_alias=AliasChoices(
            "DATABASE_URL",
            "ITDA_DATABASE_URL",
        ),
    )

    # Supabase project configuration
    supabase_url: str = ""
    supabase_publishable_key: str = Field(default="")
    supabase_service_role_key: SecretStr = SecretStr("")

    # JWT configuration
    supabase_jwks_url: str = Field(
        default="",
        validation_alias=AliasChoices(
            "SUPABASE_JWKS_URL",
            "ITDA_SUPABASE_JWKS_URL",
        ),
    )
    supabase_jwt_issuer: str = Field(
        default="",
        validation_alias=AliasChoices(
            "SUPABASE_JWT_ISSUER",
            "ITDA_SUPABASE_JWT_ISSUER",
        ),
    )
    supabase_jwt_algorithm: str = Field(
        default="",
        validation_alias=AliasChoices(
            "SUPABASE_JWT_ALGORITHM",
            "ITDA_SUPABASE_JWT_ALGORITHM",
        ),
    )
    supabase_jwt_secret: str = Field(
        default="",
        validation_alias=AliasChoices(
            "SUPABASE_JWT_SECRET",
            "ITDA_SUPABASE_JWT_SECRET",
        ),
    )
    sync_cursor_secret: SecretStr = SecretStr("")

    # Other services
    llm_api_key: SecretStr = SecretStr("")
    llm_model: str = "gemini-3.8-flash"
    fcm_credentials_path: str = ""

    @model_validator(mode="after")
    def validate_settings(self):
        if self.mode == "fixture" and self.environment == "production":
            raise ValueError("Fixture mode must never be deployed")

        # 테스트 환경에서는 .env의 운영용 JWT 설정을 사용하지 않는다.
        if self.environment == "test":
            self.supabase_jwks_url = ""
            self.supabase_jwt_issuer = ""
            self.supabase_jwt_algorithm = ""
            self.supabase_jwt_secret = ""

        return self

@lru_cache
def get_settings() -> Settings:
    return Settings()
