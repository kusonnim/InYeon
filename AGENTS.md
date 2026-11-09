# ITDA agent entry point

ITDA connects what people save with what comes next. It saves shared content,
produces a source-grounded summary, and optionally suggests useful actions,
information, or resources. It is not a task generator: zero recommendations is valid.

## Read before changing code

1. Read [PRODUCT](docs/PRODUCT.md) for confirmed behavior.
2. Read [STATUS](docs/STATUS.md) for what actually exists and the next tasks.
3. Read [ARCHITECTURE](docs/ARCHITECTURE.md), then your module's README.
4. Check [OWNERSHIP](docs/OWNERSHIP.md) and [INTEGRATION](docs/INTEGRATION.md).
5. Check [OpenAPI](contracts/openapi.yaml), fixtures, and migrations before changing interfaces.

## Non-negotiable behavior

- Android share -> durable local receipt -> prompt close -> retryable API upload ->
  asynchronous analysis -> existing notification update -> mobile/web library sync.
  Never wait for inference in the share interface or acknowledge before persistence.
- Preserve original content if extraction or analysis fails. Declare source coverage;
  never invent inaccessible video details, deadlines, prices, or other facts.
- Keep source, generated interpretation, and user edits separate. Personalization
  affects recommendation priority, not source facts. Generated is not accepted.
- Analysis: `pending/processing/completed/partial/failed`. Workflow:
  `pending/completed/archived`. Notification: `active/dismissed`. Do not conflate them.
- One automatic notification per new content item by default; analysis updates it.
  Body opens details; the only quick action is **Edit / 수정하기**. Dismissal neither
  completes nor deletes content. No automatic resurrection after sync/restart.
  Explicit restoration advances generation; old dismissals cannot affect it.
- All user data is private. Authenticate, verify ownership, and retain database RLS.
  Privileged keys stay server-side; storage remains private.

## Navigation and ownership

| Area | Owner | Paths |
| --- | --- | --- |
| Mobile / Android | Developer A | `apps/mobile/` |
| API / worker / AI | Developer B | `services/backend/` |
| Web / database | Developer C | `apps/web/`, `supabase/` |
| Shared contracts | A + B + C review | `contracts/`, shared schema/state semantics |
| Project knowledge / CI | All, coordinated | `docs/`, `.github/`, this file |

Flutter/Dart and Android Kotlin talk to FastAPI/Pydantic through the versioned API.
Next.js/TypeScript uses the same contract. Supabase provides Auth, private Storage,
and PostgreSQL; a Python worker consumes PostgreSQL jobs. FCM is the planned
mobile delivery transport. Vercel and Railway are deployment targets, not deployed services.

## Authority and safe contribution

- Product behavior: `docs/PRODUCT.md`; wire format: `contracts/openapi.yaml`;
  persistence: `supabase/migrations/`; decisions: `docs/decisions/`.
  Fixtures illustrate the contract. Code must implement it. If these disagree,
  resolve the discrepancy with affected owners; do not silently pick one.
- Start a `codex/<topic>` feature branch (or the team's agreed feature prefix),
  keep `main` stable, use a PR, and coordinate before editing another owner's area.
- Interface changes update OpenAPI, Pydantic/Dart/TypeScript models, migrations,
  fixtures, tests, and docs together. Never rewrite an applied migration.
- Read local module guidance; keep mock adapters explicitly identifiable and
  replaceable. Do not describe fixture demonstrations as production behavior.
- Update affected docs when behavior/architecture changes and `docs/STATUS.md`
  after meaningful progress. Record major decisions in an ADR. Confirm changes
  to product policy with the team; do not silently redefine them.
- Never commit `.env`, tokens, private user content, signed URLs, or service keys.
- Keep Phase 0 small: no full AI engine, advanced personalization, full native
  notification implementation, production UI, iOS, Redis/Celery/vector database.

## Commands and verification

Exact setup, environment variables, and limitations are in [DEVELOPMENT](docs/DEVELOPMENT.md).

```sh
# services/backend
uv sync --group dev
uv run pytest
uv run uvicorn app.main:app --reload --host 127.0.0.1
# apps/web
npm ci
npm run typecheck
npm run build
# apps/mobile
# First bootstrap the Android runner as documented in apps/mobile/README.md.
flutter pub get
flutter analyze
flutter test
# repository root, after starting local Supabase
supabase db reset
supabase test db
```

Contract validation is part of the Python tests. Database reset is only for the
disposable local stack. Read [INTEGRATION](docs/INTEGRATION.md) for the complete
flow and [STATUS](docs/STATUS.md) for executed versus deferred checks.
