# Integration contract and checkpoints

## Common boundary

Mobile and web consume [OpenAPI](../contracts/openapi.yaml), never a worker's internal
models or raw privileged database interface. The canonical catalog and event/error
examples live in `contracts/examples/`. Web imports the catalog; Flutter packages a
copy checked by `dart run tool/sync_fixtures.dart --check`. Python contract checks
validate schemas and fixtures. Update all consumers in a shared contract PR.

The Android share and notification outboxes use bearer tokens from a Supabase
user session. The sample library and loopback contract mock use synthetic
data. Live authentication, transactional persistence, and storage authorization
require verification against the real adapters.

## Windows integration setup

Use PowerShell in separate terminals for API, web, and Android. Install Git,
Python 3.12 and uv, Node 22.6+ or 24 with npm, Flutter with Dart, a Gradle-compatible
JDK, and the Android SDK with platform-tools. Add Flutter's `bin` and Android's
`platform-tools` to `PATH` and set `JAVA_HOME` and `ANDROID_HOME` as
needed. Supabase CLI and a local Docker Linux engine are needed for the disposable
database suite. The optional PostgreSQL probe uses `psql`.

### Synthetic environment

Start FastAPI in terminal 1 from the repository root. Use a fresh shell with
fixture settings and synthetic data only. The process holds receipts, jobs, and
sync cursors in memory for the life of that process.

```powershell
Set-Location services/backend
uv sync --locked --group dev
$env:ITDA_MODE = 'fixture'
$env:ITDA_ENVIRONMENT = 'local'
uv run uvicorn app.main:app --host 127.0.0.1 --port 8000 --no-access-log
```

Start the independent web catalog preview in terminal 2. It imports the shared
catalog and opens at `http://127.0.0.1:3000` without credentials. Open the page
once and wait for the first dev compilation before running preflight.

```powershell
Set-Location apps/web
npm.cmd ci
$env:ITDA_DATA_MODE = 'fixture'
npm.cmd run dev -- --hostname 127.0.0.1 --port 3000
```

Run the checks from the root in terminal 3. The scripts use the Python standard
library. The commands use the backend environment installed in terminal 1.

```powershell
$itdaPython = '.\services\backend\.venv\Scripts\python.exe'
& $itdaPython tools/integration/preflight.py --profile fixture
& $itdaPython tools/integration/smoke.py --profile fixture
```

Expect `GET /health` to return HTTP 200 with `fixture` and `volatile-memory`.
The preflight also checks structured HTTP 401 without a valid bearer and a
successful catalog read using a fixture identity. A smoke run creates one
synthetic text item and reports the replay, readback, edit, feed, and isolation
checks. Use `--api-url` and preflight's `--web-url` to override the fixture
loopback ports. The process restart check is skipped in fixture mode.

For the Android network flow, use the separate
[Android contract mock](../apps/mobile/README.md#loopback-contract-mock).
The following command starts it on `127.0.0.1:8782` from the repository root.

```powershell
& .\services\backend\.venv\Scripts\python.exe apps/mobile/tool/mock_upload_server.py --seed-catalog --sync-page-size 2 --replay-sync-prefix
```

Build Android with `ITDA_UPLOAD_MODE=mock`, `ITDA_API_BASE_URL` and
`ITDA_SUPABASE_URL` both set to `http://10.0.2.2:8782` for the emulator, and
`ITDA_SUPABASE_PUBLISHABLE_KEY=sb_publishable_itda_mock`. In that build use the
synthetic sign-in values from the mobile README. The other local Android option
is `ITDA_UPLOAD_MODE=disabled`, which exercises offline receipt and the sample
library without upload. Keep the FastAPI fixture bearer identities, Android mock
sessions, and staging accounts in their own environments.

### Authenticated staging

Use an approved disposable HTTPS API, its Supabase project URL and publishable
key, a web URL, and two distinct, confirmed email/password accounts. Have B and C
record the API revision, database migration IDs, and Auth project used for the
run. Keep the disposable database, Storage bucket, and accounts isolated from
production. Pass account credentials through the team's secret channel.

| Order | Service or client | Configuration and startup evidence |
| --- | --- | --- |
| 1 | Supabase | C applies the checked-in migrations to the disposable project, enables password Auth, creates the two test identities, and verifies private Storage and RLS. The Auth probe calls `GET /auth/v1/health` with the publishable key. |
| 2 | FastAPI | B starts the persistent adapter in `ITDA_MODE=production` using the same Auth issuer and database. `ITDA_SUPABASE_URL` and privileged credentials belong in B's server environment. Expect `GET /health` to report `production`. Confirm 401 for absent and invalid bearers and run the authenticated smoke for data operations. The current scaffold reports `unconfigured` and returns 501 to bearer requests. |
| 3 | Analysis worker | B supplies the command, database connection, and job claim/result evidence. For the HTTP milestone, keep the worker paused or use an approved deterministic staging worker. The checked-in `python -m worker` entry point exits with a scaffold message. |
| 4 | Web | In a separate web shell set `ITDA_DATA_MODE=api`, `ITDA_API_BASE_URL`, `NEXT_PUBLIC_SUPABASE_URL`, and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` to the approved tuple and run `npm.cmd run dev` locally. Use HTTPS for hosted sessions. Expect the signed-out library to redirect to `/login` and render the sign-in page. |
| 5 | Android | Use the staging settings below and follow the [Android staging build and device checks](../apps/mobile/STAGING.md). Confirm the **ITDA Staging** package and destination in Account before signing in. |

In the integration and Android build shell, set the staged variables using the
approved values. Use base URLs without the `/v1` and `/auth/v1` route prefixes.
The examples are placeholders. Keep generic Android endpoint settings in the
separate mock/live shells.

```powershell
$env:ITDA_UPLOAD_MODE = 'staging'
$env:ITDA_STAGING_API_BASE_URL = 'https://api.staging.example.test'
$env:ITDA_STAGING_SUPABASE_URL = 'https://project-ref.supabase.co'
$env:ITDA_STAGING_SUPABASE_PUBLISHABLE_KEY = Read-Host 'Staging publishable key'
$itdaPython = '.\services\backend\.venv\Scripts\python.exe'
& $itdaPython tools/integration/preflight.py --profile staging --web-url 'https://web.staging.example.test'
```

If C supplies read-only database access, set `PGHOST`, `PGDATABASE`, `PGUSER`,
and `PGPORT` in that shell. Configure the password file and SSL settings required
by the disposable instance. Add `--check-db` to preflight to issue a read-only
catalog query for the content, job, and sync tables. Keep PostgreSQL credentials
server-side or in the authorized operator shell. A successful probe establishes
connectivity and table presence. See the [data guide](../supabase/README.md) for
migration, RLS, and Storage verification on a disposable local stack.

Supply the two staging accounts explicitly before running the smoke. This
PowerShell example masks password entry, passes values through the environment,
and clears the four values after the run.

```powershell
$env:ITDA_SMOKE_A_EMAIL = Read-Host 'Disposable account A email'
$env:ITDA_SMOKE_A_PASSWORD = [Net.NetworkCredential]::new('', (Read-Host 'Account A password' -AsSecureString)).Password
$env:ITDA_SMOKE_B_EMAIL = Read-Host 'Disposable account B email'
$env:ITDA_SMOKE_B_PASSWORD = [Net.NetworkCredential]::new('', (Read-Host 'Account B password' -AsSecureString)).Password
& $itdaPython tools/integration/smoke.py --profile staging
Remove-Item Env:ITDA_SMOKE_A_EMAIL,Env:ITDA_SMOKE_A_PASSWORD,Env:ITDA_SMOKE_B_EMAIL,Env:ITDA_SMOKE_B_PASSWORD
```

The harness signs in at the approved Auth endpoint and uses the resulting access
JWTs against the configured API. It verifies readback, one matching catalog item
after replay, a versioned edit and a stale conflict, sync events, and B's denied
read. The run leaves its synthetic item in the disposable account. With the
operator's staging restart scheduled, add `--restart-check` in an interactive
terminal. The harness pauses while the operator restarts the API process. After
the operator confirms startup, it signs in again and checks the edited item and
original idempotency receipt. Record the before/after process or deployment IDs
outside the harness. B and C verify the ingestion transaction and row counts in
the disposable database.

### Interpreting results

`PASS` records a completed assertion. `FAIL` indicates an observed mismatch.
`BLOCKED` identifies a missing dependency, unavailable route, or service.
`NOT TESTED` identifies an optional or downstream assertion outside the run.
Exit codes are 0 for the executed checks passing, 1 for a failure, and 2 for a
blocker without an observed failure. The harness uses direct HTTP connections,
normal TLS verification, and no redirects. Evidence contains statuses and the
synthetic marker. Keep passwords, bearer tokens, cursors, user data, and capability
URLs out of evidence and Git. See the [readiness report](INTEGRATION_READINESS.md)
for the boundary audit and executed checks.

## Deterministic analysis checks

Run the integration tests from `services/backend` with the installed backend
development environment.

```powershell
.\.venv\Scripts\python.exe -m pytest ../../tools/integration
```

The analysis tests exercise deterministic worker stages and the fixture result
writer. They check recommendation payloads, zero recommendations, partial
coverage, extraction failure, source retention, independent workflow and
notification state, and result sync. For web rendering checks, start the loopback
preview and set `ITDA_I1_WEB_PREVIEW_URL=http://127.0.0.1:3000` before running the
same tests. The [readiness report](INTEGRATION_READINESS.md#reproduce-the-checks)
also describes the test-only failed-result catalog. Flutter detail tests cover
rendering and source retention for synthetic results. Hosted model evaluation is
a separate B milestone because the free quota cannot cover the 25 cases.

## Interface checklist

| Operation | Shared behavior |
| --- | --- |
| Create content | Owner/operation-scoped idempotency; original preserved; server receipt after commit; async job |
| List/detail | Owner-only representations; cursor pagination; source and generated output distinct |
| Edit content/recommendation/preferences | Explicit expected version; HTTP 409 on conflict; refetch before intentional retry |
| Feedback | Idempotent explicit event; generation never implies acceptance |
| Dismiss notification | Generation + expected revision; independent workflow; stale generation cannot hide restored state |
| Restore notification | Explicit idempotent request; expected generation/revision; new generation only when dismissed |
| Sync | Owner-scoped ordered events; cursor after complete local page application; refetch changed entities |
| Asset upload/read | Owned private object; temporary capability; completion verification before attachment |

Read endpoint schemas for exact fields, status codes, headers, errors, upload method,
pagination limits and cursor rules. Do not construct cursors or storage paths in clients.

## Mock-to-real transition

1. **Independent fixture milestone (Phase 0):** A and C render the same catalog and
   handle absent/partial analysis without depending on B's worker. B tests contract
   errors, retries and notification transitions in a local fixture repository.
2. **Identity/data milestone:** C applies migrations to disposable local Supabase
   and runs pgTAP. B implements real JWT verification, owner-scoped repositories,
   transactional ingestion/job enqueue and idempotency. Two identities must be
   tested against both API and RLS. A/C replace API adapters, keeping fixture tests.
3. **Durable Android milestone:** Phase A1 saves the original and its pending
   outbox record before acknowledging the share. Phase A2 adds account-bound
   WorkManager delivery, private asset verification, and receipt reconciliation.
   The loopback mock supports isolated client verification while B and C
   deliver the live adapters.
4. **Analysis milestone:** B implements bounded extraction and provider adapters,
   validates generated output, claims leased PostgreSQL jobs, and atomically saves
   results plus sync events. Simulate partial extraction and provider failure first.
5. **Notification/sync milestone:** Android persists dismissals, uses versioned
   restore and edits, and refreshes authoritative content. Phase A5 persists the
   library and consumes the existing sync feed with cursor expiry recovery. C
   integrates cursor sync and editing conflicts. B and A agree on device
   registration and dispatch, then exercise delayed and duplicate FCM delivery.
6. **Deployment milestone:** real authorization/storage/worker/OS evidence, separate
   staging secrets, operational retry/retention policies, and repository protections
   precede Railway/Vercel deployment. No production deployment is part of Phase 0.

Replace one adapter at a time. Do not make screens dependent on a hosted model or
add temporary privileged credentials to clients to bypass missing server work.

## End-to-end acceptance procedure for the real adapters

Use a disposable database, two test identities, one Android device/emulator, and a
web browser. Keep credentials out of recorded evidence.

1. Share an announcement offline. Confirm durable receipt and prompt close without
   a title/category/prompt. Kill/restart the process before upload; verify retry.
2. Reconnect and submit the same idempotency key/body repeatedly and concurrently.
   Assert one content row, one initial analysis job and one eligible notification.
   Reusing that key with changed content must conflict. A genuinely new share uses
   a new key and can create a separate item even for the same URL.
3. Delay inference. The API responds after storage without waiting for it. Fail the
   worker and confirm the original content and attached objects remain available.
4. Process scholarship, recipe, reflection, inaccessible URL and partial-source
   fixtures. Check grounded facts, declared coverage, zero recommendations where
   appropriate, and no implicit acceptance.
5. Dismiss before analysis completes; synchronize and restart the app. Confirm
   workflow is unchanged, the item remains in web, and no automatic notification
   reappears. Repeat offline while an older FCM result arrives.
6. Explicitly restore; then deliver a delayed dismissal from the prior generation.
   Verify restored generation remains active and replayed restore is a no-op.
7. Edit the same version on mobile and web. One succeeds, the other gets 409; refetch
   and deliberately resolve. No source or generated text is overwritten by user edits.
8. Start a full sync and insert an item newer than the first catalog page after
   that page is read. Verify catch-up includes it. Repeat with edits and deletes,
   disconnect, stop the client process during an incremental page, and expire
   the cursor. Verify offline copies, atomic recovery and replay without
   duplicates. Compare each owner's Android and web views after reconnection.
9. As user B, request user A's content/recommendation/asset and attempt direct table
   writes. Assert API denial, RLS isolation, no private download, and no service key
   in either bundle. Exercise uncompleted/wrong-owner assets and expired capabilities.
10. Verify notification body opens the correct details and Edit is the only quick
    action. Verify denied notification permission leaves saved library data intact.

Record command/build/device versions, assertions, failures, and remaining limitations
in STATUS. Full E2E completion requires actual OS and real adapter execution.

## Android live dependencies

- Developer B supplies verified Supabase JWT authentication and durable,
  owner-scoped content, preferences, private asset and notification adapters.
  Mutations must commit their related events and idempotency receipts with the
  underlying state. Content edits need the documented conflict response.
- Developer B exposes the persistent `GET /v1/sync` stream in per-owner commit
  order. A cursorless request starts at retained history and returns a usable
  checkpoint even for an empty account. New events continue strictly after the
  cursor's boundary. Expired or wrong-scope cursors produce `invalid_cursor`.
  Reads of changed resources must observe commits visible in the feed. Stable
  catalog ordering and feed catch-up must cover writes during full bootstrap.
- Developer C applies the migrations on disposable Supabase and verifies the
  owner sequence and event writes under concurrent commits. Two real identities
  must verify RLS, notification visibility, account-scoped cursors and private
  object access. Web sync must retain content after dismissal.
- Developers A and B agree on device registration, revocation and FCM dispatch.
  A delivery hint can trigger the authenticated refresh path.

## Phase A6 staging handoff

Use the [Android staging runbook](../apps/mobile/STAGING.md) and record evidence
in [STATUS](STATUS.md#phase-a6-real-staging-evidence). Agree on a matching
staging API, Supabase Auth project and web environment before testing. Share
the deployment revision and schema versions with A. Provision two disposable
email/password users and pass their credentials through the team's approved
secret channel. Client builds take the project's publishable key.

### Developer B

- Verify JWT signature, issuer, audience, expiry and subject. Every resource
  and cursor is scoped to the verified subject. Missing or invalid JWTs return
  structured `401 unauthorized`. A foreign resource returns `404 not_found`.
- Provide authenticated `GET/POST /v1/contents`, `GET/PATCH /v1/contents/{id}`,
  and `GET /v1/preferences`. Before a `201` acknowledgment, atomically commit
  the content, owned verified asset bindings, analysis job, initial
  notification, sync event, and scoped idempotency record. Exact replay
  returns the original response across API restarts. Changed payload under
  the same key returns `409 idempotency_conflict`. A stale edit returns
  `409 version_conflict` with the current version.
- Provide private asset reservation and completion through
  `POST /v1/assets/uploads` and `POST /v1/assets/{id}/complete`.
  Return a short-lived HTTPS capability for the server-selected object.
  Verify owner, bytes, hash and MIME before completion or attachment.
  Expired unverified reservations return `409 upload_expired`. Keep
  `413`, `415`, and `422` validation distinct from retryable `503`.
- Persist `POST /v1/notification-events` and
  `POST /v1/contents/{id}/notification/restore` mutations with scoped
  idempotency. Return the current generation and revision on
  `409 notification_conflict`. Dismissal leaves workflow unchanged.
  Only explicit restoration increments generation, and older-generation
  dismissal leaves that generation active. Analysis updates an existing
  notification without changing dismissal.
- Expose `GET /v1/sync` with durable per-owner commit ordering, replayable
  opaque cursors, tombstones, and read-after-commit visibility. Return
  `400 invalid_cursor` on expiry or scope mismatch. Verify catch-up during
  keyset pagination and coordinate a way to exercise lost acknowledgment,
  cursor and capability expiry, and deletion with synthetic staging data.

### Developer C

- Provide the applied migration IDs and executable pgTAP results from a
  disposable database. Verify actual Supabase identities against owner reads,
  anonymous denial, direct write denial and server-only relations. Confirm
  same-owner sync sequences follow commit order under concurrency.
- Verify the `content-assets` bucket stays private. With two real identities,
  prove A's verified object is readable only by A, B cannot upload or
  complete it, and anonymous access fails. Confirm clients receive only
  the publishable key and intended short-lived capabilities.
- Point the authenticated web library at the same staging API and project.
  Compare both accounts' web and Android libraries after edits, dismissal,
  deletion and reconnect. Exercise simultaneous version-checked edits.

The Android notification refresh path can consume a future delivery hint.
FCM staging acceptance requires the verified HTTP and storage path above,
then an agreed device registration, revocation and dispatch contract between
A and B. Provision a staging Firebase app for the isolated package and
keep the generation and suppression checks in the existing refresh path.
