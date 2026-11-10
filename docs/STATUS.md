# Implementation status

Last updated 2026-11-10 (Asia/Seoul). **Phase A5 Android library synchronization.**

Android stores an account-scoped server snapshot and incremental checkpoint
alongside the existing A1/A2 local originals and A3 notification records.
The unified library supports offline restarts and safe full rebuilds after
cursor expiry. Android verification uses synthetic Supabase sessions and an
OpenAPI mock. Live authorization, persistence, private storage, web sync, and
FCM delivery remain integration work.

## Delivered foundation

| Area | Implemented now | Explicitly incomplete |
| --- | --- | --- |
| Onboarding | Root AGENTS, product/architecture/development/ownership/integration docs, ADRs | Evolving decisions require future updates |
| API contract | Versioned OpenAPI, UUID/UTC/bearer conventions, errors, version conflicts, idempotency, cursor sync, private asset lifecycle | Real HTTP authentication, storage and persistence adapters |
| Backend | FastAPI health/router/model/config structure, fail-closed production mode, explicit in-memory fixture adapter | Persistent ingestion, Supabase JWT, uploads, real worker operations |
| Worker | Separate extraction/summarization/recommendation/persistence interfaces | PostgreSQL claim/lease/retry, actual extraction, hosted LLM, result transactions |
| Data | 12 owned tables including all nine required tables, RLS, private bucket, notification/sync helper functions, pgTAP suite | Live migration execution and adapter wiring |
| Web | Next.js library/detail, Tailwind/local shadcn-style primitive, shared types, HTTP abstraction, fixture rendering | Login, real editing, pagination UI, persistent sync, production UI |
| Mobile | Offline Android receipt, account-bound WorkManager outboxes, Supabase session client, mock-verified content and private assets, native notifications, versioned editor, durable offline library and incremental sync | Two-account live API/RLS verification, private attachment preview, FCM delivery |
| Collaboration | Feature-branch/PR rules, PR template, CI definitions, dependency lockfiles for Python/web/mobile | GitHub branch protection, team account mapping |

Phase A5 starts from the merged Phase A4 implementation in main at `86ee764` (PR #4).

## Verification evidence

| Check | Current evidence / limitation |
| --- | --- |
| SQL parsing | Passed with temporary pglast 8.7: both migrations (27 and 14 statements), test script (60 statements), all four PL/pgSQL functions |
| API/SQL consistency | Passed: 9 HTTP model mappings and enums against 12 explicitly owned tables |
| pgTAP | 33 assertions authored; **not executed** locally because Docker Linux engine is not running and Supabase CLI/psql are absent |
| Backend tests | Passed: 13 tests, including mock idempotency/concurrency, owner isolation, version conflict, independent states, source/edit preservation, and worker stage validation |
| OpenAPI and examples | Passed: specification validation, runtime schema parity, 11 example payload checks |
| Web tests/typecheck/build | Passed: 2 HTTP adapter tests, `next typegen && tsc --noEmit`, and production `next build --webpack` under Node 24 |
| Web production HTTP smoke | Passed: library 200 with catalog/fixture marker, detail 200 with source/analysis, missing content 404; test server stopped |
| Full real E2E | Pending authenticated server adapters, analysis, and notification delivery |
| GitHub Actions | See the PR checks for hosted results |
| Agent onboarding | Independent repository-only audit completed; retention and client-integration evidence gaps corrected; see [audit record](ONBOARDING_AUDIT.md) |

Python 3.12.14 and uv 0.13.7 were made available for backend verification; Node
24.15.0 and npm 11.12.1 are present. Initial sandbox DNS restrictions required
approved dependency-download retries. CI pins Python 3.12, uv 0.13.7, Node 24,
Flutter 3.47.9 and Supabase CLI 2.118.0.

Unsuccessful local attempts and resolutions: initial sandbox package downloads
failed DNS resolution; approved downloads completed. Windows sandbox restrictions
blocked TestClient's asyncio loopback setup; the approved synthetic test run passed.
The default Next.js Turbopack CSS worker could not initialize on this host; web
scripts now select the supported Webpack path. Sandbox prerender filesystem access
also failed; the approved production build completed. These resolved environment
failures do not substitute for live database checks.
One upstream Starlette/AnyIO deprecation warning remains in the passing Python run.

### Phase A1 Android checks

Local toolchain was Flutter 3.47.8, Dart 3.13.7, and JDK 21. The device was
the disposable ITDA_A1 Android 15 / API 35 x86_64 emulator. Device evidence
covers this emulator.

| Check | Result |
| --- | --- |
| Flutter | Locked dependency resolution, `flutter analyze`, five `flutter test` cases, and the canonical fixture check passed |
| APK | `flutter build apk --debug --target-platform android-x64` passed and the APK installed on the emulator |
| Native tests | Six `:app:connectedDebugAndroidTest` cases passed. Delaying the commit kept the receiver open, and recreating it yielded one committed receipt before RESULT_OK. The suite also checked replay, private file copies, unreadable URIs, and interrupted writes |
| Android share sheet | Chrome text and URL and Files PNG and PDF all produced pending receipts with airplane mode enabled and no default network. Chrome and Files returned to the foreground after each share. The text started ITDA cold, and the URL refreshed the existing Flutter library on resume |
| Restart and file durability | After deleting the synthetic source files and force-stopping ITDA, all four local IDs and client event keys survived. Both private copies still matched the original SHA-256 and the Flutter list showed all four pending entries beside the fixture catalog |
| Failure paths | An ungranted document URI and a file blocking creation of the inbox directory each produced an error toast and left the receipt count unchanged |

### Phase A2 Android checks

Local verification used Flutter 3.47.8, Dart 3.13.7, JDK 21, and disposable
Android 15 / API 35 x86_64 emulators. The API and Supabase session tests used
synthetic identities and local HTTP mocks.

| Check | Result |
| --- | --- |
| Flutter and build | Locked dependency resolution, analysis, six Flutter tests, the fixture copy check, and x86_64 debug APK builds passed. The default and mock APKs installed on emulators |
| Android lint | Zero errors and five warnings after escaping the Windows drive separators in the generated local SDK properties |
| Native instrumentation | All 17 cases passed, including the six A1 cases. The A2 suite covered request bodies and keys, image/PDF verification, interrupted PUT and completion, reservation expiry, token refresh and rejection, cross-account isolation, transient and permanent failures, and original retention |
| In-place upgrade | All four A1 receipt JSON records, IDs, and retry keys matched after APK replacement. Both private attachment hashes matched. Legacy receipts required assignment after sign-in |
| Offline and reconnection | Five receipts stayed queued through an offline force-stop and relaunch. After connectivity returned, text and URL acknowledged in the background. The PNG and PDF resumed from their persisted reservation checkpoints after a transport fix and test scheduler reset. Both were verified and attached before their content IDs were stored |
| Lost acknowledgment | The mock committed one content record and delayed the response. Killing ITDA before the 201 arrived led to one idempotent replay and a stored content ID while the launcher was foregrounded |
| Account switch and final reconnect | A share assigned to account A stayed local and redacted under B with zero content creates. Signing back in to A resumed it. A new offline share on the updated build moved from pending to synchronized after reconnecting with the launcher foregrounded |
| Loopback adapter | The standalone mock passed a schema-validated reservation expiry, replacement, byte verification, content replay, and changed-payload rejection check |
| Live integration | Pending B's Supabase JWT verifier, durable content and private asset adapters, and C's private bucket and RLS verification with two Supabase identities |

### Phase A3 Android checks

Local verification used Flutter 3.47.8, Dart 3.13.7, JDK 21, and disposable
Android 15 / API 35 x86_64 emulators. Network testing used a schema-validated
loopback API and synthetic users.

| Check | Result |
| --- | --- |
| Flutter and build | Locked dependency resolution, canonical fixture check, analysis, 10 Flutter tests, and debug x86_64 APK builds passed. Both upload-disabled and mock-configured builds installed |
| Android lint | Zero errors and six warnings after escaping drive separators in the generated Windows SDK properties |
| Native instrumentation | All 29 tests passed, including 17 A1/A2 regressions. A3 tests cover durable suppression, replay and conflict handling, account scope, stale generations, Android card identity and actions, and delete-intent delivery versus programmatic cancel |
| Android navigation and permission | On API 35, a cold share posted its initial card with the launcher foregrounded. Permission denial kept a synchronized mock receipt without issuing a card. Granting permission posted one card. With the app process stopped, its body opened the correct source. The sole **수정하기** action opened the warm editor. A title change reached the mock and kept workflow pending |
| Android shade and offline durability | A completed mock analysis updated the existing Android notification key. Repeating the result kept one card. A real offline swipe persisted suppression and its key across process termination and relaunch. Delayed partial analysis left the card absent |
| Android reconnect and restore | WorkManager reconciled the offline swipe after a same-generation revision conflict. Restore queued offline and stayed hidden. After reconnect, the mock and Android showed one active card for generation 2. A delayed generation 1 dismissal left it active |
| Android account changes | Signing out hid A's card without a dismissal. B received its own card, and A's delayed analysis and stale navigation intent exposed no A content. Signing back in to A loaded the latest details and kept the previously issued card absent |
| Loopback contract | Two-user HTTP checks passed for owner denial, optimistic edit and notification conflicts, idempotency replay and payload mismatch, stale-generation dismissal, and source and workflow retention |
| Live integration | Pending B's verified JWT and durable owner-scoped content, notification and private asset adapters, and C's disposable Supabase RLS and private object checks. FCM registration and dispatch require an agreed contract |

See the [Android presentation ADR](decisions/0005-android-notification-presentation.md)
for the Android issuance and swipe/update race limits.

### Phase A4 Android checks

Local verification used Flutter 3.47.8, Dart 3.13.7, JDK 21, and disposable
Android 15 / API 35 x86_64 emulators.

| Check | Result |
| --- | --- |
| Flutter | Locked dependency resolution, localization generation, canonical fixture check, static analysis, and 17 tests passed. Widget checks covered fixture separation, local originals, catalog merging and errors, account changes, version conflicts, notification routes and restore, and labeled Android tap targets at 320 logical pixels and 2× text scale |
| Android | Default and mock x86_64 debug APK builds passed and installed. All 31 instrumentation tests passed, including 29 A1–A3 regressions. Lint reported zero errors and six warnings |
| Visual inspection | Opened the library and details in light and dark Android modes. Checked the dark library at 1.30× system font size and verified the adjusted layout above the gesture bar. Reviewed the account screen and the offline state on the same emulator |
| Android flows | A share saved in airplane mode opened its original. Reconnection produced one merged synchronized card. The actual notification body opened the item after process termination and **수정하기** opened the editor. A mock HTTP 409 kept the title draft, then a deliberate save preserved the newer server note and original. A real swipe stayed hidden through later analysis, and explicit restore produced one generation-2 card |
| Android account isolation | Signing out hid the restored card while its server visibility stayed active. Account B saw one redacted device receipt and none of account A's catalog content |
| Contract mock | Verified owner-bound keyset pagination, invalid cursor recovery, late inserts, cross-owner denial, optimistic version conflicts, and inclusion of archived and dismissed items. App tests and emulator flows used synthetic data |
| Live integration | Pending B's verified JWT and durable catalog, edit, upload and notification adapters. C's disposable Supabase checks still need two real test identities and private object verification. Incremental sync and FCM remain separate milestones |

### Phase A5 Android checks

Local verification used Flutter 3.47.8, Dart 3.13.7, JDK 21, and Android 15 /
API 35 x86_64 emulators.

| Check | Result |
| --- | --- |
| Flutter | Locked dependencies, localization, fixture parity, analysis, and 19 tests passed. The suite includes an offline server-only preview, tombstone filtering, account switches with in-flight reads, draft preservation and version conflicts, and large-text light/dark rendering |
| Android | Default and mock x86_64 debug APKs built and installed. All 37 instrumentation tests passed, including 31 A1–A4 regressions. A5 tests cover catch-up during a paginated bootstrap, replay and related changes, interrupted SQLite transaction rollback, cursor expiry, invalid ordering, and account/realm isolation. Lint reported zero errors and six warnings |
| Android emulator with loopback mock | A concurrent insert above the held first catalog page arrived in a 13-item snapshot. Airplane-mode restart showed a server-only source preview and a pending local original. Reconnect without manual refresh applied a server edit and merged the acknowledged local original into one card |
| Process interruption | Killed the emulator app process during a held detail GET for an incremental page. The on-device SQLite row and cursor were unchanged after termination. Relaunch replayed and committed the edit with an advanced cursor |
| Cursor expiry and account switch | The old snapshot remained readable during a held rebuild after expiry. Publication hid the deleted server card and kept its local receipt and acknowledgment. Account B saw its own server item while account A's cached content and assigned original remained private |
| Android notifications | A swipe in the Android shade dismissed a synthetic item. Delayed analysis reached SQLite with visibility still dismissed and workflow still pending. Relaunch kept the item in the library and the card absent from the shade |
| Contract mock | A schema-validated HTTP smoke test verified multiple pages and replays, two synthetic accounts and owner-bound cursors, expired cursors, preference events, optimistic edit conflicts, delayed analysis after dismissal, and deletion tombstones |
| Live integration | The merged backend still uses an in-memory fixture repository. Live Supabase JWT verification, durable owner-scoped HTTP and sync adapters, private object verification, and two-identity staging API/RLS checks remain pending |

The staged bootstrap restarts after interruption. The incremental worker
resumes at the last durable page. An offline server-only view requires a
previously synchronized snapshot for the installed account and API realm.
Android checks used emulators. Physical-device and staging checks are pending.

## Next concrete tasks

### Developer A — Mobile

1. With B and C, verify ingestion, private uploads, notification mutations,
   edits, and durable sync in staging with two Supabase identities. Exercise
   concurrent bootstrap writes, page interruption, cursor expiry and conflicts.
2. Agree with B on FCM device registration, revocation and dispatch. Connect
   delivery hints to the authoritative refresh path and exercise delayed,
   duplicate and cross-account delivery.

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
| Sync retention/bootstrap expiry | B + C | Per-owner commit order chosen. Android recovery verified against the mock. Retention policy and live cursor validation remain open |
| Idempotency retention | A + B + C | Keep receipts for the lifetime of their effect until a safe retention policy is agreed |
| JWT verification/rotation and auth session UX | A + B + C | Android password and refresh flow tested with a mock; live project and backend JWT validation pending |
| Analysis history and user-edit preservation on rerun | B + C | One current analysis; preserve source/generated/user distinctions; history migration needs review |
| GitHub rules and deployment environments | Team | PR workflow documented; repository protection/secrets not configured here |

Do not resolve these by changing confirmed product policies silently. Update the
appropriate contract/ADR and obtain affected owner review.
