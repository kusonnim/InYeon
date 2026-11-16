# ITDA local integration lab on Windows

Run these commands from the repository root in PowerShell. The lab uses the
existing I1 preflight and smoke, FastAPI fixture, Android contract mock, Web
catalog and deterministic analysis checks. The authenticated profiles connect
the production API to Supabase Auth and PostgreSQL. Start the worker separately.

## Setup

Install Git, uv with Python 3.12 or 3.13, Node 22.6+ or 24, Flutter with Dart,
and the Android SDK and a Gradle-compatible JDK. The script can find Flutter
and the Android SDK through the mobile runner's ignored
`apps/mobile/android/local.properties`. See the
[Android setup](../apps/mobile/README.md#run-and-verify) for the Gradle wrapper.

```powershell
.\tools\integration\lab.ps1 Setup
.\tools\integration\lab.ps1 Check
```

`Setup` uses the backend lockfile and an ignored virtual environment under
`.cache/itda-lab`. It installs the locked npm dependencies when Web has no
Next.js installation. Select a compatible interpreter with
`Setup -Python <path-to-python.exe>` if uv needs one. `-Offline` uses existing
package caches for Setup and Flutter. The lab reads its own profile settings.
Use a lab checkout free of the Web app's automatically loaded `.env` files.

## Profile A — Synthetic

```powershell
.\tools\integration\lab.ps1 Start -Profile Synthetic
.\tools\integration\lab.ps1 Preflight -Profile Synthetic
.\tools\integration\lab.ps1 Smoke -Profile Synthetic
.\tools\integration\lab.ps1 Contract -WebPreview
.\tools\integration\lab.ps1 Stop
```

| Loopback URL | Process |
| --- | --- |
| `http://127.0.0.1:8000` | FastAPI fixture. The I1 smoke uses `fixture-user-a` and `fixture-user-b`. |
| `http://127.0.0.1:8782` | Android mock Auth and API, seeded with the shared catalog. It issues its own synthetic sessions. |
| `http://127.0.0.1:3000` | Read-only Next.js fixture catalog. |

The two API processes maintain independent in-memory receipts and identities.
The deterministic analysis suite covers recommendations, zero recommendations,
partial coverage and extraction failure. For the additional Web failed-detail
case, follow the [isolated catalog procedure](INTEGRATION_READINESS.md#web-rendering-of-a-synthetic-failure)
on port 3001. Use `.cache/itda-lab/backend-venv/Scripts/python.exe` and select
`ITDA_I1_WEB_FAILED_FIXTURE=1` as described there.

`Start` checks ports before launching and probes the expected HTTP responses.
A repeated start reuses the managed processes. Use `Stop` before switching
profiles or applying changed settings. It stops the recorded process trees after
checking their creation times and paths. Runtime state and synthetic logs live
under `.cache/itda-lab`. Stop the emulator separately through its window or with
`adb -s <selected-emulator-serial> emu kill`.

Next.js can regenerate `next-env.d.ts` and agent instructions when it starts.
Keep those generated changes out of lab and B commits.

### Android emulator

Create a disposable Android 15 / API 35 Google APIs x86_64 AVD in Android Studio.
Select the AVD name and optionally its separate AVD home. Disconnect other
device targets before launching or running the instrumentation suite.

```powershell
.\tools\integration\lab.ps1 Flutter
.\tools\integration\lab.ps1 Android
.\tools\integration\lab.ps1 Emulator -Avd ITDA_Lab
.\tools\integration\lab.ps1 Android -Avd ITDA_Lab -Instrumented
.\tools\integration\lab.ps1 Emulator -Avd ITDA_Lab -InstallMock
```

Run `-InstallMock` with Profile A running. The debug build points to
`http://10.0.2.2:8782` for both Auth and API, and installs into the selected
emulator. Sign in using the [Android mock accounts](../apps/mobile/README.md#loopback-contract-mock).
Use `-Headless` for a background emulator, or `-AvdHome <directory>` for an
AVD outside Android Studio's default directory. For instrumentation, keep the
emulator unlocked.

## Profile B — C1 staging Auth and local apps

Review the [C1 handoff](../supabase/integration/HANDOFF.md).
[`lab-targets.json`](../tools/integration/lab-targets.json) pins its HTTPS
Auth origin. Obtain the publishable key, two disposable accounts and the
server-side PostgreSQL TLS URL through the team's private handoff. Use the
direct or session-pooler PostgreSQL address. Set an independent sync signing
secret and retain it across API restarts. Copy
[the staging template](../tools/integration/lab-staging.env.example) to
`.env.lab.staging` or set its variables in the current PowerShell process.
Environment values override the file. Use literal `NAME=value` lines without
quotes or inline comments. The two lab files are Git-ignored.

```powershell
.\tools\integration\lab.ps1 Start -Profile Staging
.\tools\integration\lab.ps1 Preflight -Profile Staging
.\tools\integration\lab.ps1 Smoke -Profile Staging
.\tools\integration\lab.ps1 Stop
```

FastAPI uses its authenticated application mode on `127.0.0.1:8000`.
Next.js uses API mode on `127.0.0.1:3000` and needs the C1 public key to render
its sign-in page. Use a private browser session for each authenticated profile.
The existing smoke leaves one synthetic text item in disposable account A when
the persistent API is available. There are no database lifecycle commands for
C1 in this lab. C manages the hosted schema and test accounts.

Select the expected JWT algorithm using the matching template. Preflight reads
the public JWKS, then checks freshly issued JWTs from both disposable accounts.
It checks the algorithm, issuer, audience and subject, and matches the public
key ID for ES256 or RS256. Supabase Auth confirms each JWT through
`/auth/v1/user`. An advertised public key alone cannot identify the algorithm
currently used for newly issued sessions. HS256 relies on Auth confirmation for
this check. The C1 profile derives the API issuer and JWKS URL from the pinned
origin. Only the API receives the database, cursor and optional Storage credentials.
[Supabase JWT documentation](https://supabase.com/docs/guides/auth/jwts)

**BLOCKED** — authenticated Android access requires a device-trusted HTTPS
API. The staging build still requires HTTPS for API and Auth. The local
loopback HTTP API is for host clients. Device acceptance will also need a
matching approved Auth origin and the persistent adapter.

### Disposable local Supabase alternative

Start Docker Desktop's Linux engine and install Supabase CLI. When the CLI
is outside PATH, set `ITDA_LAB_SUPABASE_CLI` to its executable path. Use the
separate `Local` profile and [local template](../tools/integration/lab-local.env.example).

```powershell
.\tools\integration\lab.ps1 Check -Profile Local
.\tools\integration\lab.ps1 DatabaseStart -Profile Local
.\tools\integration\lab.ps1 DatabaseTest -Profile Local
```

The script creates a unique project and a loopback Docker network for a copy of
the existing Supabase config, migrations and database tests. The workdir is
`.cache/itda-lab/database`. API, PostgreSQL and Studio use ports 55421, 55422
and 55423. Port 55420 is reserved for the shadow database. Startup applies the
checked-in migrations to a fresh disposable database. The copy captures the
schema at creation. Give later schema revisions a fresh workdir in a separate
verification checkout. [Supabase local development](https://supabase.com/docs/guides/local-development)

On this Windows host, Docker Desktop published the CLI ports on all
interfaces despite the network option. `DatabaseStart` stopped the stack
and preserved the isolated migration volume. Full local Auth and API-mode
Web with that stack remain **BLOCKED** until the local runtime honors the
loopback bindings. The SQL suite can run on the stopped volume, through the
PostgreSQL container's own socket:

```powershell
.\tools\integration\lab.ps1 DatabaseTest -Profile Local -Isolated
```

This uses the existing pgTAP file and verifies the migration IDs and private
bucket. It needs the lab-created volume and the cached PostgreSQL
`17.6.1.171` image from Supabase CLI 2.118.0.

### Schema lint if only PostgreSQL can bind to loopback

After stopping the lab database stack, the following runs the existing
Supabase schema lint against the same migrated volume. The single published
port explicitly binds to loopback. Set `ITDA_LAB_SUPABASE_CLI` to the CLI path.

```powershell
$env:DOCKER_HOST = 'npipe:////./pipe/dockerDesktopLinuxEngine'
Remove-Item Env:DOCKER_CONTEXT -ErrorAction SilentlyContinue
$itdaDb = (Resolve-Path .cache/itda-lab/database).Path
$itdaMatch = Select-String -LiteralPath "$itdaDb/supabase/config.toml" -Pattern '^project_id = "(itda-lab-[a-f0-9]{8})"$'
if (-not $itdaMatch) { throw 'Expected the disposable lab config.' }
$itdaId = $itdaMatch.Matches[0].Groups[1].Value
$itdaVolume = "supabase_db_$itdaId"
if (docker ps --filter "volume=$itdaVolume" --format '{{.Names}}') { throw 'Stop the disposable stack first.' }
docker run -d --rm --pull never --name $itdaVolume --network $itdaId -p 127.0.0.1:55422:5432 `
    --mount "type=volume,source=$itdaVolume,target=/var/lib/postgresql/data" public.ecr.aws/supabase/postgres:17.6.1.171
if ($LASTEXITCODE) { throw 'Could not start the local lint database.' }
try {
    if ((docker port $itdaVolume '5432/tcp') -ne '127.0.0.1:55422') { throw 'Unexpected port binding.' }
    foreach ($attempt in 1..20) {
        docker exec $itdaVolume pg_isready -U postgres -d postgres -q
        if (-not $LASTEXITCODE) { break }
        Start-Sleep -Seconds 1
    }
    if ($LASTEXITCODE) { throw 'The local lint database did not become ready.' }
    & $env:ITDA_LAB_SUPABASE_CLI db lint --local --level error --fail-on error --workdir $itdaDb
    if ($LASTEXITCODE) { throw 'Schema lint failed.' }
} finally { docker stop $itdaVolume | Out-Null }
```

### Local Auth and HTTP smoke

Continue after the disposable Auth gateway is listening on
`127.0.0.1:55421` and both migrations have applied. With the CLI stack,
create two confirmed synthetic users in local Studio
(`http://127.0.0.1:55423`). Export their credentials and issued JWT algorithm
using the [Local template](../tools/integration/lab-local.env.example). Capture the
CLI's connection settings in the process environment:

```powershell
$itdaCli = if ($env:ITDA_LAB_SUPABASE_CLI) { $env:ITDA_LAB_SUPABASE_CLI } else { (Get-Command supabase.exe).Source }
$itdaLocal = & $itdaCli status --workdir .cache/itda-lab/database -o json 2>$null | ConvertFrom-Json
$env:ITDA_LAB_LOCAL_PUBLIC_KEY = if ($itdaLocal.PUBLISHABLE_KEY) { $itdaLocal.PUBLISHABLE_KEY } else { $itdaLocal.ANON_KEY }
$env:ITDA_LAB_LOCAL_DATABASE_URL = $itdaLocal.DB_URL
if ($env:ITDA_LAB_LOCAL_JWT_ALGORITHM -eq 'HS256') {
    $env:ITDA_LAB_LOCAL_JWT_SECRET = $itdaLocal.JWT_SECRET
}
Remove-Variable itdaLocal
```

Set `ITDA_LAB_LOCAL_SYNC_CURSOR_SECRET` from 32 random bytes and retain it
through the restart check. A loopback Docker setup can publish only the Auth
gateway and PostgreSQL using explicit `127.0.0.1` mappings. Use the gateway's
`/auth/v1` route for GoTrue. Verify the bindings with `docker port`.

```powershell
.\tools\integration\lab.ps1 Start -Profile Local
.\tools\integration\lab.ps1 Preflight -Profile Local
.\tools\integration\lab.ps1 Smoke -Profile Local -RestartCheck
.\tools\integration\lab.ps1 Stop
.\tools\integration\lab.ps1 DatabaseStop -Profile Local
```

Database stop preserves local volumes. The database tests exercise SQL and
policies on the disposable stack. The restart smoke confirms the edited receipt
and the pre-restart sync checkpoint after restarting the API.

Run the opt-in production audit with both Local accounts and the database URL
exported in the current shell. Start with a disposable database and an empty
Worker queue. Run the audit before the I1 smoke, which creates its own queued
receipt.

```powershell
$env:ITDA_TEST_LOCAL_PRODUCTION = '1'
Push-Location services/backend
try {
    ..\..\.cache\itda-lab\backend-venv\Scripts\python.exe -m pytest -q ../../tools/integration/test_production_api.py
} finally {
    Pop-Location
    Remove-Item Env:ITDA_TEST_LOCAL_PRODUCTION
}
```

The audit validates HTTP responses against OpenAPI and runs the PostgreSQL
worker with deterministic analysis. Run a hosted model check separately with
approved credentials and quota.

### URL and private image audit

Use a fresh disposable database with the two repository migrations. Run GoTrue,
PostgreSQL and Supabase Storage behind loopback-only listeners. Expose the Auth
and Storage routes at `/auth/v1` and `/storage/v1` on the gateway. For the Local
launcher, set `ITDA_LAB_LOCAL_SERVICE_ROLE_KEY` in the Local profile. For a
direct API launch, set `ITDA_SUPABASE_URL` to the loopback gateway and set
`ITDA_SUPABASE_SERVICE_ROLE_KEY` in the server process. Export the same
Storage and database settings to the audit process for its injected worker.
Keep other workers stopped so the audit can claim and assert each job.

From `services/backend`, after exporting the two disposable Local accounts:

```powershell
$env:ITDA_TEST_LOCAL_PRODUCTION = '1'
$env:ITDA_TEST_LOCAL_STORAGE = '1'
$env:ITDA_TEST_PUBLIC_URLS = '1'
uv run pytest -q ../../tools/integration/test_production_api.py
```

The local defaults are `http://127.0.0.1:8000` for FastAPI and
`http://127.0.0.1:55421` for the Supabase gateway. Override them with
`ITDA_TEST_LOCAL_API_URL` and `ITDA_TEST_LOCAL_AUTH_URL` when using an isolated
set of ports. The public URL cases make read-only requests to Example Domain
and the HTTPBingo Basic Auth fixture. The Storage cases issue real signed PUTs,
use owner-scoped readback, and consume the images from the worker. Deterministic
analysis callbacks assert the input and exercise result persistence.

For a hosted demo, configure an approved Gemini `ITDA_LLM_API_KEY` with access
and quota for the selected model. Set `ITDA_LLM_MODEL` to `gemini-3.6-flash` in
the worker process to match the live local verification. Run
`uv run python -m worker` against the same disposable database and Storage.
Create fresh receipts for supplied text, a public page, and a synthetic
recruitment poster. Compare the summary and
recommendations with the source and verify the final state through detail and
sync. For Android, use device-reachable trusted HTTPS for the API and the
matching Auth and Storage gateway.

## Validate Developer B's incoming work locally

Keep the baseline lab changes on `codex/local-integration-lab`. Use a separate
verification worktree for B's application and any adapter-specific lab wiring.
PR #17 at `01e5131` was integrated in `.cache/pr17-src` on
`codex/pr17-local-integration`. See [STATUS](STATUS.md#pr-17-local-integration)
for its evidence.

```powershell
git worktree add -b codex/local-b-verification ..\ITDA-b-verification codex/local-integration-lab
```

- **Git bundle** — verify the local bundle with `git bundle verify <path>`.
  Inspect `git bundle list-heads <path>`. Import the selected ref with
  `git fetch <path> refs/heads/<b-branch>:refs/heads/codex/incoming-b`.
  Review the commit range and common ancestor, then merge the imported branch
  only in the verification worktree. This keeps B's original commit IDs.
- **Patch** — review a plain diff and use `git apply --check <path>`, then
  `git apply <path>` in the verification worktree. For a reviewed
  `git format-patch` series, use `git am --3way <path>` to preserve the
  author and commit messages. Resolve any conflicts in the verification worktree.
- **Directory** — keep the incoming directory intact. Compare and copy only
  the reviewed source changes into the verification worktree's
  `services/backend`. Review additions, edits, and deliberate removals.
  Leave credentials, virtual environments and generated outputs in their
  originating locations. Commit the import separately from lab wiring.

Read B's settings and map only the approved profile's server credentials into
the FastAPI process. Match JWT issuer, audience and verified signing mode to
the selected Auth origin. If B uses PostgreSQL directly, use the disposable
local database or the C1 TLS connection from C's private handoff. Keep the
database password, JWT secret and privileged keys in server-only environment
variables or ignored configuration. The lab currently maps the Auth base and
public client configuration. The profile templates name the settings consumed
by the current adapter.

Run `Setup`, `Contract`, `Web`, and `Flutter` there. Run the authenticated
profile against the disposable local database first, then C1 when the two
accounts and matching server settings are available. Keep the worker stopped
for the initial HTTP milestone. Once it has a deterministic test provider,
verify durable receipts, one analysis job, result sync, and owner isolation.
Run `Smoke -Profile Local -RestartCheck` or `Smoke -Profile Staging -RestartCheck`
from an interactive host terminal. Stop and restart the selected lab app
processes in a second terminal when prompted, keeping Supabase running.
Continue with the [real-adapter acceptance procedure](INTEGRATION.md#end-to-end-acceptance-procedure-for-the-real-adapters).

Keep temporary imports, credentials and raw test evidence out of the PR.

## Result labels

`PASS` marks an executed assertion, `FAIL` an observed mismatch, `BLOCKED` a
missing prerequisite, and `NOT TESTED` an unexecuted downstream check.
Preflight and smoke use exit codes 0, 1, and 2 for passing checks, failures, and
blockers respectively. Record only status, outcome, version and sanitized
test evidence. See [implementation status](STATUS.md#local-integration-lab).

To reproduce the eight C1 verifier regression tests using files already in Git:

```powershell
$itdaC1 = (Join-Path (Get-Location).Path '.cache/itda-lab/c1-verifier')
New-Item -ItemType Directory -Path $itdaC1 -Force | Out-Null
git archive --format=tar --output="$itdaC1/c1.tar" d739cd3 supabase/integration tools/integration
tar.exe -xf "$itdaC1/c1.tar" -C $itdaC1
.\.cache\itda-lab\backend-venv\Scripts\python.exe -m unittest discover -s "$itdaC1/supabase/integration" -p 'test_*.py'
```
