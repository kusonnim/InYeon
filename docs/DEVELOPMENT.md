# Development

Read [AGENTS](../AGENTS.md), [STATUS](STATUS.md), and your module README first.
Commands below run from the repository root unless a `cd` is shown. Use separate
terminals for independent apps. No cloud credentials are needed for fixture work.

## Prerequisites

- Git; Node.js 22 or 24 and npm for web (the lockfile is authoritative).
- Python 3.12 and uv for backend; use `uv sync --locked --group dev` after checkout.
- Flutter stable with Dart, Android SDK and an emulator/device for mobile.
- Docker Engine/Desktop running Linux containers and Supabase CLI for local DB tests.

The tested versions and unavailable tools are recorded in STATUS. CI pins its
toolchain. Do not assume a green source review means native or database tests ran.

## Backend

```sh
cd services/backend
uv sync --locked --group dev
uv run uvicorn app.main:app --reload --host 127.0.0.1 --port 8000
uv run pytest
uv run python -m app.contract_tools --check
```

Copy `.env.example` to `.env` if configuring local mode. The safe default is
`ITDA_MODE=production`: health works, but data integrations are not implemented and
fail closed. For a disposable local fixture API, set `ITDA_MODE=fixture` and keep
`ITDA_ENVIRONMENT=local`. Fixture bearer tokens are `fixture-user-a` and
`fixture-user-b`. They are synthetic test identities, not Supabase authentication.
Bind only to loopback. Restart clears in-memory changes; it is not durable storage.
Never deploy fixture mode or use real private content in it.

The module README explains worker invocation. Real Supabase URL, privileged server
credential, LLM API key and FCM credential path are placeholders for future adapters.
Their presence does not implement those integrations. Store secrets in local `.env`
or deployment secret management, never client bundles or committed files.

## Web

```sh
cd apps/web
npm ci
npm run dev
npm run typecheck
npm test
npm run build
```

Open `http://localhost:3000`. Fixture mode renders the shared synthetic catalog;
see `apps/web/.env.example` and README for the mode switch and server-only API
configuration. Do not add a service key to a `NEXT_PUBLIC_` variable. Real user
session plumbing remains work; use the API adapter only once authentication is wired.
The preview routes are a library and `/contents/<uuid>` detail view. No desktop
notification permission is required.

Web scripts use Next.js's Webpack option because the default Turbopack CSS worker
could not start on the authoring Windows host. Typecheck explicitly generates route
types first, so it works before the initial build on a clean checkout.

## Mobile

```sh
cd apps/mobile
# One-time Android project generation; do not pass --overwrite.
flutter create --platforms=android --org com.itda --project-name itda_mobile .
dart run tool/sync_fixtures.dart
flutter pub get
flutter analyze
flutter test
flutter devices
flutter run -d <android-device>
```

Read `apps/mobile/README.md` before bootstrapping; app source is checked in, while
the platform runner is generated with the installed SDK. Keep the generated runner
in A's future PR after a successful native build. Kotlin contracts under
`native/android/` are intentionally unregistered placeholders. The scaffold must
not advertise Android share receipt until durable URI handling/outbox exists.
The fixture sync command copies canonical JSON assets for Flutter packaging; rerun
it after contract changes and run its consistency check in CI.

Android emulator networking differs from loopback on the host. Configure the local
API origin explicitly when implementing the live adapter; never weaken production
TLS or embed a privileged credential to make local development work.

## Database

From the repository root, with the local Docker engine running:

```sh
supabase start
supabase db reset
supabase test db
supabase db lint --level error
```

These commands target a **disposable local stack**. `db reset` destroys local data;
never use a linked/remote reset for routine checks. See `supabase/README.md` for
table policies, schema mapping and test prerequisites. Do not hand-edit a remote
database as a substitute for committed migrations. Keep storage private.

## Contracts and debugging

OpenAPI is authoritative. The backend contract checker detects API/schema drift
and validates example payloads; its tests also exercise error/status semantics.
Read the fixture README for how examples are mapped to schemas. Clients should
retain server versions and idempotency keys, not infer them from local timestamps.

For API failures, inspect the structured error code and request identifier.
For duplicates, check owner + operation + idempotency key and payload equality.
For notification races, inspect generation/revision and local pending dismissals
before changing workflow state. For sync gaps, inspect transactional sequence
allocation and committed cursor, not FCM arrival order. Do not log bearer tokens,
source content, private file bodies, or signed URLs.

## Contributing

Keep `main` stable. Start a `codex/<topic>` feature branch, coordinate ownership,
use the PR template, and request review from affected owners. GitHub branch
protection is an administrator task; workflow files alone cannot enforce it.
Run the checks for your changed modules and contract consumers. Report limitations
in the PR and STATUS. Update docs/ADRs when behavior, architecture, or contracts
change. No independent renaming of shared fields or state semantics.

Do not add unrelated infrastructure or finish full product features during Phase 0.
Mock-to-real integration follows [INTEGRATION](INTEGRATION.md).
