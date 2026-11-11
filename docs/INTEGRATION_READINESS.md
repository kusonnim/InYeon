# I1 integration readiness

Reviewed `origin/main` at `cb8338a52c4b` on 2026-11-12 (Asia/Seoul), including
the merged Android detail changes, Web session and library changes, and B's
standalone AI extractor. I1 exercises the existing interfaces on Windows and
provides a staging acceptance path. The two-account authenticated staging run
is blocked by the missing B adapters and the unavailable approved staging
API/Auth/web tuple and test accounts.

## Boundary audit

| Boundary and owner | Implementation and compatibility | Executed evidence and dependency |
| --- | --- | --- |
| Android share to receipt and outbox · A | `ShareReceiverActivity` and `LocalShareStore` publish a private original and pending upload record before receipt success. `AndroidOutbox` schedules the account-bound operation. | Android instrumentation and prior airplane-mode share-sheet checks exercise receipt, copied bytes, retry identity, and reopening originals. See [I1 runs](STATUS.md#i1-windows-verification) for the current emulator result. |
| Outbox to Auth and FastAPI · A + B | `SupabaseSessions` exchanges and refreshes access tokens. `UploadPipeline` submits the retained key and `ContentCreate`, and stores the returned content ID. Android's loopback mock speaks that wire format. FastAPI's `current_user` recognizes only fixture tokens and returns 501 for a production bearer. | Native outbox transport tests and the fixture HTTP smoke verify their respective synthetic boundaries. B must validate Supabase JWTs and derive the same owner from verified `sub` before a real share can upload. |
| API receipt to PostgreSQL · B + C | FastAPI installs `FixtureRepository` only in fixture mode. The migration defines owned `contents`, `content_assets`, `idempotency_records`, notifications, and `sync_events`. There is no SQL-backed request path. | The fixture HTTP smoke shows repeat 201, one catalog match, and source readback. SQL tests and mapping check are listed below. B must commit content, owned ready asset links, job, initial notification, event and receipt together before 201. |
| PostgreSQL content to analysis job · B | `analysis_jobs` has job state, attempts, and lease fields. The fixture creates an in-memory queued job with the content. | Backend tests observe one job under concurrent fixture create. The deployed transaction, claim, lease expiry, and retry behavior need a consumer and a disposable database run. |
| Job to extraction and AI stages · B | `worker.pipeline` defines stages and checks identity, coverage, and generated acceptance. `python -m worker` exits at the scaffold. `extractors/ai_extractor.py` accepts supplied text and returns a separate provider result. It has no connection to job claims or the wire output. | Deterministic stage tests executed with no provider call. B must supply a job consumer and a validated mapping from provider status and `action/info/material` to API analysis states, coverage, and `action/information/resource`. The helper imports `openai`, which is absent from `uv.lock`. Lock the provider dependencies before scheduling the hosted evaluation. |
| Result to persistence and sync · B + C | `AnalysisPersistence` defines the success-write boundary. `FixtureRepository.apply_analysis` simulates result/status writes and sync. The PostgreSQL worker transaction and failure mapping are absent. | I1 round-trips completed recommendations, zero recommendations, partial coverage and failed extraction. Results preserve source, title, workflow and dismissal. B must persist the guarded result or terminal failure, job transition and feed event together and preserve concurrent edits and explicit acceptance. |
| Result to Android notification · A + B | `LibrarySyncEngine` refetches affected content and hands eligible updates to the A3 refresh path. Durable local suppression, generation and revision govern existing cards. SQL transition functions exist. Production API notification writes and FCM dispatch are pending. | Native notification state/transport tests and earlier contract-mock device checks cover stable cards, dismissal, and restore. A and B need authenticated notification transactions, then agreed device registration, revocation and FCM dispatch. |
| PostgreSQL changes to mobile and web libraries · A + B + C | The SQL helper allocates owner-scoped sequences. The fixture emits opaque cursors. Android checkpoints SQLite pages and bootstraps/catches up after expiry. Web polls in-tab, refreshes server-rendered results and loads a fresh snapshot on entry. | Fixture HTTP sync and cross-owner cursor rejection, native cache tests and Web sync unit tests ran. B must wire retained history and expiry into a committed feed. C and A must prove convergence with the same two real accounts and API. |
| Private object upload/read · A + B + C | Android implements reservation, PUT, and completion against the contract mock and can open retained local files. The API reservation, completion and download routes are 501. Web shows attachment counts. | Synthetic Android transport exercises file validation and checkpoints. B must issue verified owner-scoped capabilities. C must prove private Storage access under real identities and add Web opening through the signed download endpoint. |

## Cross-client contract audit

| Interface | Android | Web | Live integration action |
| --- | --- | --- | --- |
| API and Auth base | Staging Gradle build embeds `ITDA_STAGING_*`; HTTPS, isolated debug package and realm. Mock uses `10.0.2.2:8782` on the emulator. | Server uses `ITDA_API_BASE_URL`; Auth uses `NEXT_PUBLIC_SUPABASE_*`. Dev supports loopback HTTP. | Integration Lead and C map the same approved API and Supabase tuple into separate shells. Check the destination in Android Account and the Web sign-in route. |
| JWT and ownership | Kotlin exchanges a password for a Supabase session, scopes originals and caches by realm and account, and sends the user's access JWT. | Next verifies the cookie-backed session claims and forwards the access JWT on server-side API calls. | B validates tokens on every `/v1` request and scopes resources and cursors to verified `sub`. C tests owner reads and RLS independently of API denial. |
| Content response | Native catalog bridge and Dart model consume nested snake_case `Content`; Android joins the registered ID to the local original. | TypeScript expects the same nested `Content` for list, detail and versioned edits. | B returns the reviewed fields, UUIDs, timestamps, nullability and ownership on list/detail/PATCH. Run the two-account smoke and compare renders. |
| Sync cursor | Opaque cursor plus `BigInteger` sequences. SQLite commits page changes with the checkpoint and recovers from `invalid_cursor`. | Opaque cursor plus `BigInt` sequences. Refreshes relevant parents and restarts the tab feed after `invalid_cursor`. | B serves strict per-owner commit order, read-after-commit, parents and tombstones. C and A test concurrent bootstrap changes, expiry and reconnect. |
| Workflow | `pending/completed/archived` are editable independently of analysis and notification. | Same enum and versioned update. | Verify both clients agree after edit, archive, restore and dismissal. |
| Version conflicts | Sends `expected_version` and retains a stale draft for deliberate retry. | Sends `expected_version` and retains/rebases content and recommendation drafts. | B maps the atomic compare to `409 version_conflict` with `current_version`. Reproduce simultaneous Android/Web edits. |
| Recommendations | Displays the generated `action/information/resource` entries and corrected wording; empty arrays are valid. | Same representation. Edits `user_text` and explicitly changes acceptance through the recommendation PATCH. | B preserves provenance, `text`, `user_text`, acceptance, and versions across result retries. |
| Assets | Uploads owned ready assets; local image/PDF originals can open offline. Server-only private image retrieval is pending. | Reads `asset_ids` and displays the count. | B supplies `GET /v1/assets/{id}/download-url` with short expiry and `no-store`. A and C wire owner-checked opening with no capability persistence. |
| Notification independence | Android shows/updates or suppresses an existing generation. Dismissal leaves workflow and library membership intact. | Renders visibility separately from analysis and workflow. | B persists versioned dismissal and explicit restore. A/C verify a dismissed item still appears in both libraries after sync. |

The exercised synthetic transports are the FastAPI fixture bearer adapter,
the Android loopback Auth/API mock, and the Web fixture catalog. The Android
mock tokens and FastAPI fixture bearers belong to different test servers.
Authenticated staging requires matching Supabase user JWTs on both clients.

## Reproduce the checks

Follow the [Windows runbook](INTEGRATION.md#windows-integration-setup) for service
startup and preflight/smoke commands. Run the source and interface tests from
the repository root with the locked backend, web, and mobile dependencies.

```powershell
Push-Location services/backend
uv sync --locked --group dev
uv run pytest
uv run python -m app.contract_tools --check
uv run python ../../supabase/verify_contract.py
.\.venv\Scripts\python.exe -m pytest ../../tools/integration
Pop-Location

Push-Location apps/web
npm.cmd ci
npm.cmd run typecheck
npm.cmd test
npm.cmd run build
Pop-Location

Push-Location apps/mobile
flutter pub get --enforce-lockfile
dart run tool/sync_fixtures.dart --check
flutter analyze
flutter test
Set-Location android
.\gradlew.bat :app:assembleDebug :app:assembleDebugAndroidTest :app:lintDebug
# With only the disposable Android emulator connected:
.\gradlew.bat :app:connectedDebugAndroidTest
Pop-Location
```

For the local database suite, point the Supabase CLI at a fresh disposable
workdir containing a copy of `supabase/config.toml`, `supabase/migrations`, and
`supabase/tests`. Give the copy a unique project ID and separate local ports and
volumes. Start the Docker Linux engine before starting the stack.

```powershell
supabase start --workdir $itdaDbCopy
supabase test db --workdir $itdaDbCopy
supabase db lint --local --level error --fail-on error --workdir $itdaDbCopy
```

`start` applies the migrations on the fresh local stack. I1 used CLI 2.118.0
via `npm.cmd exec --yes --package supabase@2.118.0 -- supabase` on Windows. See
[data setup](../supabase/README.md#local-verification) and the
[I1 evidence](STATUS.md#i1-windows-verification).

### Web rendering of a synthetic failure

The shared preview catalog already covers recommendations, partial coverage,
and a zero-recommendation case. To exercise the failed-detail branch, create a
disposable local catalog copy with the recipe's failure state. Run these commands
from the repository root.

```powershell
$itdaCopy = Join-Path (Get-Location).Path '.cache\i1-failed-preview'
New-Item -ItemType Directory -Path $itdaCopy | Out-Null
$itdaArchive = Join-Path $itdaCopy 'source.tar'
git archive --format=tar --output=$itdaArchive HEAD apps/web contracts
tar.exe -xf $itdaArchive -C $itdaCopy
$itdaCatalogPath = Join-Path $itdaCopy 'contracts\examples\catalog.json'
$itdaCatalog = Get-Content -LiteralPath $itdaCatalogPath -Raw -Encoding utf8 | ConvertFrom-Json
$itdaRecipe = $itdaCatalog.items | Where-Object id -eq '10000000-0000-4000-8000-000000000002'
$itdaRecipe.analysis_status = 'failed'
$itdaRecipe.analysis = $null
$itdaRecipe.recommendations = @()
[IO.File]::WriteAllText($itdaCatalogPath, (ConvertTo-Json -Depth 32 -InputObject $itdaCatalog))
Set-Location (Join-Path $itdaCopy 'apps\web')
npm.cmd ci
$env:ITDA_DATA_MODE = 'fixture'
npm.cmd run dev -- --hostname 127.0.0.1 --port 3001
```

Once the detail route responds, run the rendered-text assertions in a separate
terminal in `services/backend`.

```powershell
$env:ITDA_I1_WEB_PREVIEW_URL = 'http://127.0.0.1:3001'
$env:ITDA_I1_WEB_FAILED_FIXTURE = '1'
.\.venv\Scripts\python.exe -m pytest ../../tools/integration/test_synthetic_analysis.py -k web_presentation
```

Flutter's `test/content_details_test.dart` covers generated output, empty
recommendations, partial coverage and original retention after failure. The
deterministic checks do not spend model quota. B's reported free quota cannot
cover the separate 25-case hosted evaluation.

## Owner handoff and acceptance

| Owner | Next required change | Evidence to bring back |
| --- | --- | --- |
| B · Auth and repository | Implement JWT signature, issuer, audience, expiry and subject verification in `app/auth.py`. Bind the verified owner to the persistent repository and cursor in `app/main.py` and `app/routers.py`. Implement catalog/detail/PATCH/sync with structured 401, 404, 409 and `invalid_cursor`. | Stage revision, successful password/JWT request for A and B, B's denied A detail, commit-ordered feed, and stale-version error. |
| B · Ingestion | Make idempotency reservation/check, original receipt, initial notification, job and sync event atomic with source persistence. Bind verified assets within the same transaction once supported. | Lost acknowledgment/replay and concurrent replay leave one row, job, and initial notification. Restart the API and show the same receipt and edited source record. |
| B · Worker and assets | Supply a runnable claim/lease/retry consumer and a deterministic result provider for staging. Persist success and failure with lease guard, owner scope, source preservation and sync. Implement private reservation/verified completion/short-lived read. | Execute one leased success, zero-recommendation result and failed job on the disposable database. Show sync/readback, preserved edits, and owner-only Storage transfer. |
| B + A · Notifications | Wire the live generation/revision mutations first. Then agree on and implement device registration, revocation and durable dispatch with FCM as a refresh hint. | Same Android card updates after analysis. Offline dismissal remains suppressed after restart, stale dismissal leaves restored generation active, and replay produces no duplicate. |
| C · Supabase | Provision the disposable Auth/DB/Storage environment, apply `202611090001` and `202611090002`, and supply two confirmed test accounts. Verify RLS with real identities, public denial and private bucket bytes, including denied foreign reads/writes and server-only relations. | Migration IDs, pgTAP/lint output, real owner and foreign outcomes, and private signed-capability checks. |
| C · Web | Configure `ITDA_DATA_MODE=api` and the same API and Auth project as Android. Wire private opening after B ships the download capability. | Signed-in Web and Android see matching source, versions and states. A stale edit preserves its draft and B sees only B's library. |
| Integration Lead + A | Pin the same deployment revision, migration IDs, tuple and Android package. Run preflight, API smoke with restart, then Android share and Web round trip. Keep the harness and contract regression evidence with the run. | Sanitized route statuses, Android/API process restart evidence, row and job counts, and both account views. |

**Next milestone.** Use two real disposable Supabase accounts to verify one
offline Android text share through API restart and Web convergence. A's share
reconnects and receives a durable 201. Exact replay keeps one item and job. A
edits the title on Web and Android receives the same version from sync. B cannot
read A's item, list it, or reuse A's cursor. B and C verify the database
transaction and RLS, and the integration lead records all results. Run this
milestone with the worker paused or with a deterministic test result. Private
file transfer, worker and notification delivery, and hosted model evaluation
have their own acceptance cases.
