# Backend and analysis foundation

Owner: Developer B. Read [root AGENTS.md](../../AGENTS.md), then [the API contract](../../contracts/openapi.yaml) before changing interfaces.

## Run locally

Python 3.12 and uv are required. From `services/backend`:

```sh
uv sync --locked --group dev
uv run uvicorn app.main:app --reload --host 127.0.0.1 --port 8000
uv run pytest
uv run python -m app.contract_tools --check
```

Set the production adapter values in the process environment or the ignored
`.env` using [the server template](server.env.example). Apply both repository migrations
before starting the API.

- `ITDA_DATABASE_URL` is the server-side PostgreSQL URL. For hosted Supabase,
  use the approved TLS connection and the direct or session-pooler address.
- `ITDA_SUPABASE_JWT_ISSUER` and `ITDA_SUPABASE_JWKS_URL` identify the selected
  Auth realm. Set `ITDA_SUPABASE_JWT_ALGORITHM` to its issued signing algorithm.
  A legacy HS256 stack uses `ITDA_SUPABASE_JWT_SECRET` with the JWKS URL empty.
  The verifier requires an `authenticated` audience and a UUID subject.
- `ITDA_SYNC_CURSOR_SECRET` is an independent server secret. Generate it from
  at least 32 random bytes and share it across API processes in the same realm.
  Rotating it invalidates old cursors and requires clients to bootstrap again.
- `ITDA_SUPABASE_URL` is the origin of the Supabase gateway for the same realm.
  HTTPS is required outside the local or test environment. Loopback HTTP is
  supported for the disposable lab.
- `ITDA_SUPABASE_SERVICE_ROLE_KEY` authorizes the API and worker to access the
  private Storage bucket. Set it in the server processes only.
- `ITDA_LLM_API_KEY` is the approved Gemini API key for hosted text and vision
  inference. The existing adapter uses `gemini-3.8-flash`. [Gemini model reference](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash)

`GET /health` reports the configured persistence adapter. Verify connectivity
with an authenticated API request. Keep database and signing credentials in the
server environment or ignored configuration.

For a disposable demo, set `ITDA_MODE=fixture` and `ITDA_ENVIRONMENT=local`
and use `fixture-user-a` for the seeded catalog or `fixture-user-b` for an
empty account. Run a single loopback process. Restart clears fixture state,
jobs, cursors and idempotency receipts.

## Private asset lifecycle

1. Reserve an asset through `POST /v1/assets/uploads` with owner authentication,
   a stable idempotency key, filename, MIME type, byte count, and SHA-256.
2. PUT the original bytes to the returned capability with the supplied headers.
   The capability targets one private object and disables overwrites.
3. Call `POST /v1/assets/{id}/complete` with owner authentication and a completion
   key. FastAPI verifies the private object bytes, MIME, size, and hash before
   marking it ready. JPEG, PNG, and WebP are decoded under a 40-megapixel safety
   ceiling. The bucket and upload contract cap each file at 20 MiB.
4. Submit the ready `asset_ids` with `POST /v1/contents`. Receipt, bindings, job,
   notification, and sync event commit together.

`GET /v1/assets/{id}/download-url` returns an owner-checked signed GET for a ready
asset. The URL lasts at most 60 seconds. Keep signed URLs out of logs and sync
data. Invalid bytes, mismatched size or hash, and pending uploads stay ineligible
for attachment. Cleanup of abandoned uploads is pending.

## Worker

Run `uv run python -m worker` against the same PostgreSQL and Supabase realm.
Text jobs use the supplied text. URL jobs fetch bounded public HTML or text and
send the extracted title and body to the same text analyzer. This fetch honors
robots and access restrictions. It accepts standard HTTP and HTTPS ports and
caps the response at 1 MiB, extracted text at 32,000 characters, and the fetch at
15 seconds. Coverage describes the accessible response.

Image jobs read attached, verified JPEG, PNG, or WebP originals from private
Storage and check the bytes again before sending them to Gemini. A large image
or animation may be represented by a bounded analysis copy and carries a coverage
limitation. Generated image recommendations can name visible resources. Users
can consult the original for printed addresses. Document analysis and FCM delivery
remain pending.

A missing model key produces a partial result with an explicit limitation.
Transient failures use the existing job retry budget. Results and terminal
states are committed under a valid lease and appear via detail and sync.
The [local integration lab](../../docs/LOCAL_INTEGRATION_LAB.md#url-and-private-image-audit)
separates HTTP, Storage, database, and worker checks with deterministic inference
from checks that send inputs to the approved hosted model.

## Contract updates

`contracts/openapi.yaml` is the authoritative review artifact. Change it, models, database migration, fixtures and client types together with A/B/C review. `uv run python -m app.contract_tools --write` prepares a candidate specification from the implemented route/model declarations; inspect and review its diff. CI runs only `--check` and fails on drift; it never overwrites the authoritative contract.

The validation approach follows the [FastAPI testing documentation](https://fastapi.tiangolo.com/tutorial/testing/) and [OpenAPI 3.1 specification](https://spec.openapis.org/oas/v3.1.0). These links describe tooling, not completion of product functionality.
