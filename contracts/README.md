# Shared API contracts

`openapi.yaml` is the authoritative API review artifact. JSON uses snake_case, UUIDs and UTC ISO 8601 timestamps. All `/v1` routes require a bearer access token; `/health` is public process health only. The API is the mutation boundary. Clients do not write public application tables directly.

## Shared semantics

- `analysis_status`: pending, processing, completed, partial, failed. Independent `workflow_status`: pending, completed, archived.
- Analysis coverage: full_text, partial_text, metadata_only, unsupported. Coverage describes what was accessible, not model confidence. Unknown facts remain unknown; zero recommendations is valid.
- Immutable source text/URL and generated `analysis.summary`/recommendation `text` remain separate from editable `title`, `user_note` and recommendation `user_text`.
- Every content starts with one automatic notification eligibility (`active`, generation 1). Visibility is independent of workflow. OS delivery permission and device display are separate concerns. Notification body opens details; the only quick action is Edit (수정하기).
- Revision counts state/presentation updates within and across generations. Only explicit restoration increments generation. An older-generation dismissal is a successful ignored event. Current-generation revision conflicts return 409; refresh then reconcile. AI completion, app restart and sync never restore dismissed visibility.
- All create/event/restore/upload POSTs require `Idempotency-Key` (8–128 characters). Scope is verified user + operation (including path ID) + key. Same payload replays the original response; different payload returns 409 `idempotency_conflict`. The provisional production policy retains receipts for the lifetime of their effect, until an ADR defines safe bounded retention and recovery without duplicate ingestion. Clients retry with the same key and must not silently recreate an expired operation. Fixture receipts last only until restart.
- Editable resources use integer `expected_version`; conflict returns 409 with `current_version`. Refetch, show/reconcile changes, then retry with the new version. PATCH omission preserves a field; explicit null only clears `title`, `user_note`, `user_text` or `mbti`. Workflow, acceptance and preference arrays cannot be null.
- `POST /feedback` records feedback; it does not mutate recommendation acceptance. `PATCH /recommendations/{id}` with `accepted` explicitly changes acceptance and records corresponding feedback. Generation alone never counts as user acceptance.
- List pages sort by `(created_at, id)` descending. Cursors are opaque and owner-bound. Sync sequence is a decimal string and must be processed in owner-scoped commit order; deduplicate replayed sequences. `content_id` resolves changed recommendation/notification aggregates. Delete events retain tombstone identifiers. Production cursor retention and full bootstrap policy need an ADR before deployment.
- Structured errors use `error.code`, `message`, `request_id` and optional current version/generation/revision. Owned-resource lookups return 404 for another user's IDs. Validation errors do not echo private inputs.

## Private asset flow (contract only)

1. Call `POST /v1/assets/uploads` with filename, media type, byte count and SHA-256. The server selects a new asset UUID and private `content-assets/{user_id}/{asset_id}/source` key. JPEG/PNG/WebP/PDF/plain text are allowed, maximum 20 MiB. Filename never controls object path.
2. Upload with the returned capability and exact headers. The planned Supabase signed upload capability lasts two hours; upsert is false. Capability URLs are bearer secrets: never log or store in content/source fields.
3. Call `POST /v1/assets/{id}/complete`. Server checks ownership, actual bytes, digest, size and file signature before `ready`. Client-provided metadata alone is insufficient.
4. Include only owned, ready, unattached `asset_ids` in content creation. Attach atomically with source record/job/notification/sync/receipt. Private objects stay private.
5. Read through owner-checked `GET /v1/assets/{id}/download-url`, with an at-most-60-second signed URL and `Cache-Control: no-store`. Orphan reservation cleanup is planned.

Asset endpoints currently return 501 in every mode. Storage policy SQL is a foundation, not proof that uploads work end to end. The fixture server intentionally accepts no real files.

## Fixtures

All examples are synthetic, deterministic development data, not verified real announcements or recommendations. `example.com`, `example.org` and `example.edu` references stand in for sources. No request to those pages is necessary.

| File | Purpose |
| --- | --- |
| `examples/catalog.json` | ContentPage: university announcement, recipe, reflection with zero recommendations, inaccessible video URL, partial announcement |
| `examples/content-create.json` | Input receipt request; no title/category/prompt required |
| `examples/preferences.json` | Explicit preferences with optional MBTI absent |
| `examples/notification-dismissal.json` | Independent visibility transition |
| `examples/notification-restoration.json` | Explicit generation increment and ignored delayed dismissal |
| `examples/version-conflict.json` | Structured 409 response |
| `examples/asset-upload-create.json` | Private document upload reservation request |

The client fixtures must derive from `catalog.json`; do not fork their facts or models. From `services/backend`, `uv run python -m app.contract_tools --check` validates OpenAPI, runtime schema parity and all 11 example payloads. Client fixture checks are separate. Review contracts with all three owners before regenerating examples or changing field names.
