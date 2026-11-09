# Backend and analysis foundation

Owner: Developer B. Read [root AGENTS.md](../../AGENTS.md), then [the API contract](../../contracts/openapi.yaml) before changing interfaces.

## Run locally

Python 3.12 and uv are required. From `services/backend`:

```sh
uv sync --frozen --group dev
uv run uvicorn app.main:app --reload --host 127.0.0.1 --port 8000
uv run pytest
uv run python -m app.contract_tools --check
```

The default `ITDA_MODE=production` starts `/health` and Swagger `/docs`; data routes return 401 without a bearer token or 501 with one. No unverified JWT is accepted. `/health` is process health, not production readiness.

For a disposable demo, copy `.env.example` to `.env`, set `ITDA_MODE=fixture` and `ITDA_ENVIRONMENT=local`, then restart. Use `Authorization: Bearer fixture-user-a` (seeded examples) or `fixture-user-b` (empty independent account). Do not deploy fixture mode. Start a single process: all state, jobs, cursor signatures and idempotency receipts disappear on restart. Memory receipt tests do not prove durable Android ingestion.

Fixture routes support text/URL create, list/detail, user edits, workflow updates, recommendation acceptance, preference edits, feedback, notification dismissal/explicit restore and sync. Asset routes deliberately return structured 501; no upload capability is fabricated. The fixture tokens are test identifiers, not Supabase credentials. Do not put service-role, LLM or FCM credentials in clients or tracked files.

## Boundaries and next work

- `app/models.py`: Pydantic representations of the reviewed OpenAPI contract.
- `app/routers.py`: endpoint organization and contract semantics.
- `app/auth.py`: local fixture authentication; production JWT verification remains unimplemented.
- `app/repository.py`: replaceable volatile fixture adapter; atomicity tests use one process lock.
- `worker/pipeline.py`: extraction, summarization, recommendation and persistence interfaces. No real extraction, hosted model call, PostgreSQL queue consumer or push delivery exists.
- `tests/`: executable mock invariants and OpenAPI/fixture parity checks.

Implement Supabase JWT signature, issuer, audience and expiry checks before enabling production routes. Use the verified subject for every database access, even when server credentials bypass RLS. Implement transactional ingestion, scoped durable idempotency, private asset verification, per-user ordered sync and PostgreSQL job leases/retries next. Worker failures must preserve original sources. Worker retries must not overwrite user edits or explicit recommendation feedback. A commit must not emit or restore a dismissed notification.

Do not use `python -m worker` as a readiness check: it exits with an explicit unimplemented message. There is no production worker executable yet.

## Contract updates

`contracts/openapi.yaml` is the authoritative review artifact. Change it, models, database migration, fixtures and client types together with A/B/C review. `uv run python -m app.contract_tools --write` prepares a candidate specification from the implemented route/model declarations; inspect and review its diff. CI runs only `--check` and fails on drift; it never overwrites the authoritative contract.

The validation approach follows the [FastAPI testing documentation](https://fastapi.tiangolo.com/tutorial/testing/) and [OpenAPI 3.1 specification](https://spec.openapis.org/oas/v3.1.0). These links describe tooling, not completion of product functionality.
