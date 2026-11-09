"""Hand-maintained models: contracts/openapi.yaml is the reviewed public contract."""
from datetime import datetime
from typing import Annotated, Literal
from uuid import UUID

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, HttpUrl, model_validator

AnalysisStatus = Literal["pending", "processing", "completed", "partial", "failed"]
WorkflowStatus = Literal["pending", "completed", "archived"]
Coverage = Literal["full_text", "partial_text", "metadata_only", "unsupported"]
RecommendationKind = Literal["action", "information", "resource"]
Version = Annotated[int, Field(ge=1)]


class Model(BaseModel):
    model_config = ConfigDict(extra="forbid")


class ErrorDetail(Model):
    code: str
    message: str
    request_id: UUID
    current_version: int | None = None
    current_generation: int | None = None
    current_revision: int | None = None


class ErrorResponse(Model):
    error: ErrorDetail


class Analysis(Model):
    id: UUID
    content_id: UUID
    coverage: Coverage
    summary: str | None
    limitations: list[str]
    created_at: AwareDatetime


class Recommendation(Model):
    id: UUID
    content_id: UUID
    kind: RecommendationKind
    text: str
    source_url: HttpUrl | None
    user_text: str | None
    accepted: bool
    version: Version
    created_at: AwareDatetime
    updated_at: AwareDatetime


class NotificationState(Model):
    content_id: UUID
    visibility: Literal["active", "dismissed"]
    generation: Version
    revision: Version
    updated_at: AwareDatetime


class Content(Model):
    id: UUID
    user_id: UUID
    input_type: Literal["text", "url", "image", "document"]
    source_text: str | None
    source_url: HttpUrl | None
    asset_ids: list[UUID]
    title: str | None
    user_note: str | None
    analysis_status: AnalysisStatus
    workflow_status: WorkflowStatus
    version: Version
    created_at: AwareDatetime
    updated_at: AwareDatetime
    analysis: Analysis | None
    recommendations: list[Recommendation]
    notification: NotificationState


class ContentCreate(Model):
    input_type: Literal["text", "url", "image", "document"]
    source_text: str | None = Field(default=None, max_length=100000)
    source_url: HttpUrl | None = None
    asset_ids: list[UUID] = Field(default_factory=list, max_length=10)

    @model_validator(mode="after")
    def input_present(self):
        if self.input_type == "text" and not (self.source_text and self.source_text.strip()):
            raise ValueError("text input requires non-blank source_text")
        if self.input_type == "url" and not self.source_url:
            raise ValueError("url input requires source_url")
        if self.input_type in ("image", "document") and not self.asset_ids:
            raise ValueError("image/document input requires completed asset_ids")
        if len(set(self.asset_ids)) != len(self.asset_ids):
            raise ValueError("asset_ids must be unique")
        return self


class ContentPatch(Model):
    expected_version: Version
    title: str | None = Field(default=None, max_length=500)
    user_note: str | None = Field(default=None, max_length=10000)
    workflow_status: WorkflowStatus = Field(default=None)

    @model_validator(mode="after")
    def valid_patch(self):
        if "workflow_status" in self.model_fields_set and self.workflow_status is None:
            raise ValueError("workflow_status cannot be null")
        return self


class RecommendationPatch(Model):
    expected_version: Version
    user_text: str | None = Field(default=None, max_length=10000)
    accepted: bool = Field(default=None)

    @model_validator(mode="after")
    def valid_patch(self):
        if "accepted" in self.model_fields_set and self.accepted is None:
            raise ValueError("accepted cannot be null")
        return self


class ContentPage(Model):
    items: list[Content]
    next_cursor: str | None


class Preferences(Model):
    user_id: UUID
    interests: list[str]
    explicit_preferences: list[str]
    mbti: str | None
    version: Version
    created_at: AwareDatetime
    updated_at: AwareDatetime


class PreferencesPatch(Model):
    expected_version: Version
    interests: list[str] = Field(default=None, max_length=50)
    explicit_preferences: list[str] = Field(default=None, max_length=50)
    mbti: str | None = Field(default=None, pattern="^[IE][NS][TF][JP]$")

    @model_validator(mode="after")
    def valid_patch(self):
        for field in ("interests", "explicit_preferences"):
            if field in self.model_fields_set and getattr(self, field) is None:
                raise ValueError(f"{field} cannot be null")
        return self


class FeedbackCreate(Model):
    content_id: UUID
    recommendation_id: UUID | None = None
    event_type: Literal["accepted", "rejected", "corrected"]
    comment: str | None = Field(default=None, max_length=10000)


class FeedbackEvent(FeedbackCreate):
    id: UUID
    user_id: UUID
    created_at: AwareDatetime


class NotificationEvent(Model):
    content_id: UUID
    event_type: Literal["dismissed"]
    generation: Version
    expected_revision: Version


class NotificationRestore(Model):
    expected_generation: Version
    expected_revision: Version


class NotificationResult(Model):
    state: NotificationState
    applied: bool
    reason: Literal["applied", "stale_generation", "already_active", "already_dismissed"]


class SyncEvent(Model):
    sequence: str
    entity_type: Literal["content", "recommendation", "preferences", "notification"]
    entity_id: UUID
    content_id: UUID | None
    operation: Literal["upsert", "delete"]
    occurred_at: AwareDatetime


class SyncPage(Model):
    events: list[SyncEvent]
    next_cursor: str
    has_more: bool


class AssetUploadCreate(Model):
    filename: str = Field(min_length=1, max_length=255)
    media_type: Literal["image/jpeg", "image/png", "image/webp", "application/pdf", "text/plain"]
    size_bytes: int = Field(gt=0, le=20971520)
    sha256: str = Field(pattern="^[a-f0-9]{64}$")


class AssetUpload(Model):
    asset_id: UUID
    upload_url: HttpUrl
    upload_headers: dict[str, str]
    expires_at: AwareDatetime


class AssetComplete(Model):
    asset_id: UUID
    status: Literal["ready"]
    media_type: str
    size_bytes: int
    sha256: str


class AssetDownload(Model):
    asset_id: UUID
    download_url: HttpUrl
    expires_at: AwareDatetime


class Health(Model):
    status: Literal["ok"]
    mode: Literal["production", "fixture"]
    persistence: Literal["unconfigured", "volatile-memory"]
