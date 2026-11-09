# Implementation status

Last updated: 2026-11-09 (Asia/Seoul). Phase: **0, foundation**.

This is a local repository foundation, not a deployed or production-ready service.
Client fixture rendering and the volatile fixture API are executable starting points.
The complete Android -> real database -> AI -> notification -> web flow is planned.
Do not interpret mock tests as proof of production durability or authorization.

## Delivered foundation

| Area | Implemented now | Explicitly incomplete |
| --- | --- | --- |
| Onboarding | Root AGENTS, product/architecture/development/ownership/integration docs, ADRs | Evolving decisions require future updates |
| API contract | Versioned OpenAPI, UUID/UTC/bearer conventions, errors, version conflicts, idempotency, cursor sync, private asset lifecycle | Real HTTP authentication, storage and persistence adapters |
| Backend | FastAPI health/router/model/config structure, fail-closed production mode, explicit in-memory fixture adapter | Persistent ingestion, Supabase JWT, uploads, real worker operations |
| Worker | Separate extraction/summarization/recommendation/persistence interfaces | PostgreSQL claim/lease/retry, actual extraction, hosted LLM, result transactions |
| Data | 12 owned tables including all nine required tables, RLS, private bucket, notification/sync helper functions, pgTAP suite | Live migration execution and adapter wiring |
| Web | Next.js library/detail, Tailwind/local shadcn-style primitive, shared types, HTTP abstraction, fixture rendering | Login, real editing, pagination UI, persistent sync, production UI |
| Mobile | Flutter library/detail, Dart models/API abstractions, bundled checked fixture, Kotlin/Dart native boundaries | Generated Android runner, SDK lockfile, durable share inbox/outbox, uploads, native notifications |
| Collaboration | Feature-branch/PR rules, PR template, CI definitions, dependency lockfiles for Python/web | GitHub branch protection, actual remote CI run, team account mapping |

The original repository contained only `.git`; no existing application code was
replaced. Local work is on `codex/phase-0-foundation`. No deployment or remote PR
publication is included in Phase 0.

## Verification evidence

| Check | Current evidence / limitation |
| --- | --- |
| SQL parsing | Passed with temporary pglast 8.7: both migrations (27 and 14 statements), test script (60 statements), all four PL/pgSQL functions |
| API/SQL consistency | Passed: 9 HTTP model mappings and enums against 12 explicitly owned tables |
| pgTAP | 33 assertions authored; **not executed** locally because Docker Linux engine is not running and Supabase CLI/psql are absent |
| Flutter analysis/tests/Android run | **Not executed**: Flutter/Dart unavailable locally; Android execution was not attempted; commands and CI provided |
| Backend tests | Passed: 13 tests, including mock idempotency/concurrency, owner isolation, version conflict, independent states, source/edit preservation, and worker stage validation |
| OpenAPI and examples | Passed: specification validation, runtime schema parity, 11 example payload checks |
| Web tests/typecheck/build | Passed: 2 HTTP adapter tests, `next typegen && tsc --noEmit`, and production `next build --webpack` under Node 24 |
| Web production HTTP smoke | Passed: library 200 with catalog/fixture marker, detail 200 with source/analysis, missing content 404; test server stopped |
| Mobile fixture consistency | Passed: packaged catalog bytes match the canonical shared fixture; this does not execute Dart/Flutter |
| Full real E2E | **Not executed**: real adapters, native implementation and cloud credentials are intentionally absent |
| GitHub Actions | Workflow definitions provided; no remote run has been triggered or claimed |
| Agent onboarding | Independent repository-only audit completed; retention and client-integration evidence gaps corrected; see [audit record](ONBOARDING_AUDIT.md) |

Python 3.12.14 and uv 0.13.7 were made available for backend verification; Node
24.15.0 and npm 11.12.1 are present. Initial sandbox DNS restrictions required
approved dependency-download retries. CI pins Python 3.12, uv 0.13.7, Node 24,
Flutter 3.47.9 and Supabase CLI 2.118.0. Flutter and Supabase pins need their first
CI execution; they are not claimed as locally exercised toolchains.

Unsuccessful local attempts and resolutions: initial sandbox package downloads
failed DNS resolution; approved downloads completed. Windows sandbox restrictions
blocked TestClient's asyncio loopback setup; the approved synthetic test run passed.
The default Next.js Turbopack CSS worker could not initialize on this host; web
scripts now select the supported Webpack path. Sandbox prerender filesystem access
also failed; the approved production build completed. These resolved environment
failures do not substitute for the still-pending Flutter/live database checks.
One upstream Starlette/AnyIO deprecation warning remains in the passing Python run.

## Next concrete tasks

### Developer A — Mobile

1. Bootstrap/commit the Android runner and Flutter lockfile; run analysis, tests,
   and an emulator/device build before registering any share target.
2. Implement app-private durable source copies and outbox with stable retry keys;
   test offline receipt, URI expiry, process death, restart and duplicate retries.
3. Integrate user session and private uploads with B's authenticated API.
4. Implement independent notification state, durable local suppression and explicit
   restoration; body -> details, Edit-only action, stale-generation tests.

### Developer B — Backend and AI

1. Implement verified Supabase JWT authentication and owner-filtered DB repository;
   retain safe default behavior and two-identity negative tests.
2. Commit ingestion, asset attachment, job, sync event and idempotency receipt in
   one transaction. Implement conditional updates and conflict mapping.
3. Implement private upload completion verification and URL/document extraction
   defenses before accepting live content; preserve raw originals on failure.
4. Implement PostgreSQL job claims, leases, retries, bounded LLM adapters, validated
   coverage/results and atomic persistence. Then design durable FCM dispatch with A.

### Developer C — Web and Data

1. Start disposable Supabase, run reset/33 pgTAP assertions/lint, fix any runtime
   schema issues, and record the first actual database authorization evidence.
2. Add Supabase web session integration and replace fixture adapter; implement
   paginated library and explicit version-conflict handling for edits.
3. Implement incremental sync/bootstrap/recovery with B and verify simultaneous
   mobile/web changes. Keep dismissed items accessible.
4. Support real two-user API/RLS/private object integration tests and configure
   Vercel monorepo deployment only after live adapters are ready.

## Decisions still required

| Decision | Owners | Current boundary / proposed default |
| --- | --- | --- |
| Hosted model/provider, cost/latency budget, data retention | B + team | Hosted multimodal API required; provider/model undecided |
| Source formats, file quotas, scanning and cleanup | B + C | Contract currently proposes JPEG/PNG/WebP/PDF/text, 20 MiB; bytes verified server-side; no public objects |
| Job retries/leases and processing SLO | B | PostgreSQL queue chosen; budgets/monitoring undecided |
| FCM dispatch, device registration/revocation, multi-device delivery | A + B | One automatic eligibility per item; explicit restore only; no device API yet |
| Sync retention/bootstrap expiry | B + C | Per-owner commit order chosen; retained-history policy and full resync integration pending |
| Idempotency retention | A + B + C | Keep receipts for the lifetime of their effect until a safe retention policy is agreed |
| JWT verification/rotation and auth session UX | A + B + C | Supabase Auth chosen; production adapter/refresh handling pending |
| Analysis history and user-edit preservation on rerun | B + C | One current analysis; preserve source/generated/user distinctions; history migration needs review |
| GitHub rules and deployment environments | Team | PR workflow documented; repository protection/secrets not configured here |

Do not resolve these by changing confirmed product policies silently. Update the
appropriate contract/ADR and obtain affected owner review.
