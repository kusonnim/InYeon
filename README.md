# ITDA

**Connect what you save with what comes next.**

ITDA is an AI-powered content understanding and recommendation service. Share a
link, text, image, or document from Android; ITDA saves it promptly, analyzes the
accessible source in the background, and keeps the result in a synchronized mobile
and web library. Suggestions can be actions, information, resources, or nothing.

Phase 0 established the contracts, private database foundation, fixture-based
clients, and API/worker scaffold. Phase A1 adds offline Android share receipt
and a local outbox. Server uploads, Supabase integration, AI inference, and FCM
delivery are future integration work.

## Start here

- New coding agent: [AGENTS.md](AGENTS.md)
- Product decisions: [PRODUCT](docs/PRODUCT.md)
- Installation and commands: [DEVELOPMENT](docs/DEVELOPMENT.md)
- Current evidence and next tasks: [STATUS](docs/STATUS.md)
- Repository-only onboarding check: [audit record](docs/ONBOARDING_AUDIT.md)
- Team boundaries: [OWNERSHIP](docs/OWNERSHIP.md)
- System and integration: [ARCHITECTURE](docs/ARCHITECTURE.md), [INTEGRATION](docs/INTEGRATION.md)

## Run independently

Web fixture library:

```sh
cd apps/web
npm ci
npm run dev
```

Backend (Python 3.12+ and uv; see its `.env.example` for explicit fixture mode):

```sh
cd services/backend
uv sync --group dev
uv run uvicorn app.main:app --reload --host 127.0.0.1
```

Mobile:

```sh
cd apps/mobile
flutter pub get
flutter run -d <android-device>
```

Client fixtures require no database, AI provider, or credentials. The backend is
fail-closed outside its explicitly configured demo mode. Follow the module READMEs
before connecting clients to that demo or to future authenticated services.

## Repository

```text
apps/mobile/           Flutter app and Kotlin share receiver (A)
apps/web/              Next.js + TypeScript starting point (C)
services/backend/      FastAPI, Python worker, tests (B)
supabase/              PostgreSQL migrations and access tests (C)
contracts/             Authoritative OpenAPI and shared JSON examples (A/B/C)
docs/                  Product, architecture, development, progress, decisions
.github/               Pull request template and automated checks
```

OpenAPI and database changes require cross-owner review. Keep `main` stable, work
in feature branches, and submit PRs. Do not commit secrets. See the
[development workflow](docs/DEVELOPMENT.md#contributing).
