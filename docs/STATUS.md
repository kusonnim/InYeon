# Implementation status

Last updated 2026-11-10 (Asia/Seoul). **Phase A7.1 Android pebble tray.**

Android has a separate HTTPS-only staging installation with explicit API and
Supabase configuration. The local originals, upload outbox, notification state
and library checkpoints retain their account and realm scope. The checked-in
backend and database evidence supports local mock verification. Authenticated
staging, private storage, RLS, web consistency, and FCM remain integration work.

Android home presents saved items as rigid pebbles. **All saved** exposes the
non-archived collection, including expandable repeated-link groups. The archive
is a list. Completion, archiving, and return to pending use versioned workflow
updates. The app supports Korean and English. Details and editing show locally
available original images. Android notifications show a localized source,
title, and processing state with the existing dismissal and restoration rules.

Android details and editing open saved source and recommendation web links
through Android's external app resolution. Titles and personal notes in
editable details can focus the corresponding field in the versioned editor.

## Delivered foundation

| Area | Implemented now | Explicitly incomplete |
| --- | --- | --- |
| Onboarding | Root AGENTS, product/architecture/development/ownership/integration docs, ADRs | Evolving decisions require future updates |
| API contract | Versioned OpenAPI, UUID/UTC/bearer conventions, errors, version conflicts, idempotency, cursor sync, private asset lifecycle | Real HTTP authentication, storage and persistence adapters |
| Backend | FastAPI health/router/model/config structure, fail-closed production mode, explicit in-memory fixture adapter | Persistent ingestion, Supabase JWT, uploads, real worker operations |
| Worker | Separate extraction/summarization/recommendation/persistence interfaces | PostgreSQL claim/lease/retry, actual extraction, hosted LLM, result transactions |
| Data | 12 owned tables, RLS, private bucket, notification/sync functions, both migrations and 33 pgTAP checks executed on isolated PostgreSQL 17.5 | Full Supabase CLI stack, hosted Auth/Storage integration, and B adapter wiring |
| Web | Korean library and detail, Supabase email/password session, FastAPI cursor pagination, current-page search, version-aware edits and in-tab sync refresh, read-only fixture preview | Live API persistence and mobile interop, private attachment opening, cross-library search |
| Mobile | Offline Android receipt, account-bound WorkManager outboxes, Supabase session client, mock-verified content and private assets, native notifications, versioned editor, durable offline library and incremental sync, isolated staging build, Korean and English UI, local image preview, rigid pebble tray and versioned workflow | Two-account live API/RLS verification, server-only private image download, FCM delivery |
| Collaboration | Feature-branch/PR rules, PR template, CI definitions, dependency lockfiles for Python/web/mobile | GitHub branch protection, team account mapping |

Phase A6 starts from the merged Phase A5 implementation in main at `7883189` (PR #5).

## Verification evidence

| Check | Current evidence / limitation |
| --- | --- |
| SQL parsing | Passed with temporary pglast 8.7: both migrations (27 and 14 statements), test script (60 statements), all four PL/pgSQL functions |
| API/SQL consistency | Passed: 9 HTTP model mappings and enums against 12 explicitly owned tables |
| pgTAP | All 33 passed in isolated PostgreSQL 17.5 using PGlite and compatibility Auth/Storage tables. Full Supabase stack, CLI lint, and Auth/Storage transport remain pending. See [data setup](../supabase/README.md#local-verification). |
| Backend tests | Passed: 13 tests, including mock idempotency/concurrency, owner isolation, version conflict, independent states, source/edit preservation, and worker stage validation |
| OpenAPI and examples | Passed: specification validation, runtime schema parity, 11 example payload checks |
| Web tests/typecheck/build | Passed: 7 tests for HTTP, edit/rebase and sync semantics, `next typegen && tsc --noEmit`, and production `next build --webpack` under Node 24.21 |
| Web fixture browser smoke | Passed in Chrome: list/detail, search and clear, small viewport, missing detail and stale list cursor recovery |
| Authenticated web HTTP smoke | Passed with synthetic Auth and FastAPI: two account sessions, owner-specific responses, forged token rejection, refresh/logout, cookie flags, cursor pagination and cross-owner detail denial |
| Authenticated web browser smoke | Passed with synthetic Auth and FastAPI: HTTP 409 preserves draft, deliberate rebase retains untouched fields, versioned completion and recommendation correction, simulated mobile event refreshes detail |
| Web review regression | Passed in Chrome: concurrent content and recommendation drafts survive sync GET failure and error retry; save, cancel and logout clear the drafts |
| Full real E2E | Pending authenticated server adapters, analysis, and notification delivery |
| GitHub Actions | The workflow runs on pull requests. See the C implementation PR checks for remote results. |
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

### Phase A6 local and mock evidence

Local checks used Flutter 3.47.8, Dart 3.13.7, JDK 21 and a disposable
Android 15 / API 35 x86_64 emulator. The reviewed contract is ITDA API 0.1.0
(OpenAPI 3.1.0). The reviewed SQL migrations are `202611090001` and
`202611090002`.

| Check | Result |
| --- | --- |
| Flutter | Locked dependencies, localization, fixture parity, static analysis and all 20 tests passed. The new check verifies the staging label and destination shown before sign-in |
| Android instrumentation and lint | All 41 tests passed, including 37 A1–A5 regressions and four A6 checks for config, realm binding, network policy and redirect isolation. The first run hit an unready emulator MediaStore volume. The full rerun passed after the provider responded. Default debug lint reported zero errors and eight warnings, including two resources used by alternate build modes |
| Build validation | Seven negative Gradle checks rejected incomplete and mixed settings, HTTP, embedded URL credentials and query, a privileged key prefix, and staging release/profile tasks. Rejected settings were omitted from validation messages |
| Staging APK with example endpoints | Installed alongside the regular APK. All three staging configuration and policy checks passed. Android registered both share targets. A synthetic receipt sent to ITDA Staging was visible only in that package. The signed-out account screen showed the configured example API host |
| Installed loopback mock APK | Synthetic account A bootstrapped five catalog items alongside three redacted receipts from a prior realm. An offline text share persisted locally. Reconnection produced HTTP `201`, a durable server ID, and one merged library card. After switching to synthetic account B, A's catalog and original text were hidden. The staging receipt remained in its own package |
| Backend audit | All 13 existing Python contract and fixture tests passed locally, with one Starlette/AnyIO deprecation warning. The health route and fixture adapters execute. The production scaffold still reports unconfigured persistence |
| Preflight diagnostics | Local TestClient probes rejected fixture mode and observed production scaffold `401` for a missing token and `501` for a synthetic invalid token. A valid synthetic reservation request to the fixture API also returned `501`. The preflight rejected missing mode and cleartext before network and suppressed raw response fields and token material |

### Phase A6 real staging evidence

Live staging and physical-device checks remain pending. At the A6 audit, the
merged code and fetched branches contained no newer B/C adapter changes.
The C web increment adds session handling
and API-based editing, with live integration still pending. An approved staging
API/Auth/web tuple and two disposable Supabase accounts were unavailable. The
deployed API revision and applied database schema versions remain unverified.

| Dependency | Classification | Repository and execution evidence |
| --- | --- | --- |
| Supabase Auth with two real accounts | Blocked by infrastructure or credentials | Android exercises password and refresh with synthetic sessions. No approved Auth project or real test credentials were available |
| FastAPI JWT verification | Missing | `current_user` only recognizes fixture tokens. Non-fixture bearer requests return `501 adapter_not_implemented` |
| Owner-scoped persistent content and preferences | Missing | The fixture repository is executable and volatile. Production has no data adapter |
| Private asset reservation and verification | Missing | Reservation, completion and download routes return structured `501`. The separate Android mock exercises the upload flow with synthetic files |
| Durable idempotency records | Missing API adapter, schema implemented but unverified | The migration defines the table. Backend fixture replays are in memory. No durable transaction or cross-process replay was observed |
| Notification dismissal and restoration | Implemented and executable in fixture, missing live adapter | Fixture tests execute the transitions. SQL transition functions are authored and unverified on a deployed database |
| Commit-ordered incremental sync | Sequence allocation implemented but unverified, live feed missing | SQL serializes owner allocation. The executable fixture feed loses its cursor and events after process restart |
| PostgreSQL RLS and private object access | SQL policies verified in isolated PostgreSQL | All 33 pgTAP checks pass with compatibility Auth/Storage schemas. Full Supabase CLI and two real identities with private objects remain pending |
| Web and Android library convergence | Blocked by live adapters and staging configuration | Web sessions, versioned edits and sync are tested with synthetic Auth/API. Real two-account consistency remains pending |

The [staging runbook](../apps/mobile/STAGING.md) gives the executable build and
preflight procedure and the two-account test matrix. The
[B/C handoff](INTEGRATION.md#phase-a6-staging-handoff) lists the required server,
database and web evidence. The Android notification refresh path is ready to
evaluate delivery hints after live verification and agreement on registration,
revocation and dispatch.

### Phase A6.1 Android checks

Local checks used a disposable Android 15 / API 35 x86_64 emulator and the
existing contract mock with synthetic accounts. The app language preference is
installation-wide and independent of the device locale. Repeat-link grouping
is a display projection, and local originals remain account and realm scoped.

| Check | Result |
| --- | --- |
| Flutter | Locked dependency resolution, localization generation, fixture parity, static analysis, and all 26 Flutter tests passed. Coverage includes language switching, exact-URL expansion, labeled compact previews, field-level edits and conflict drafts, and offline image zoom |
| Android instrumentation | All 43 tests passed. The suite covers JPEG, PNG, and WebP original validation, acknowledged versus pending originals, owner isolation, missing and corrupt files, localized in-place notifications, legacy records, and generation suppression |
| Builds and lint | Default and loopback-mock x86_64 debug APK builds passed. Android lint passed with zero errors and eight warnings after escaping drive letters in the generated Windows SDK properties |
| Emulator smoke test | Observed Korean on first launch and persisted language choices after process restart. Opened the editor from the Android notification and confirmed that closing it left the mock record and version intact. Verified a repeat-link group with distinct records and a separate card for a different query. Shared a synthetic PNG from Files with networking disabled, opened its inline and expanded previews, synchronized one verified mock asset, and reopened the original offline and in the editor |

The checked-in private download route returns `501 adapter_not_implemented`.
Server-only images show an unavailable preview until Developer B provides the
owner-scoped adapter and Developer C verifies private bucket access. Share
subjects stay in local receipts. A separate A/B/C contract review is needed
to preserve that metadata across devices.

### Phase A6.2 Android checks

A6.2 starts from the merged A6.1 implementation in main at `00e345e` (PR #7).
The original link works on local and synchronized items before analysis.
Opening a resource or an original requires a user action and an absolute HTTP
or HTTPS URL. The client filters recognized credential parameters and private
storage routes. Copying or opening a link leaves its stored value intact.
Direct edits use the existing authenticated detail and version checks.

| Check | Result |
| --- | --- |
| Flutter | Locked dependency resolution, localization generation, fixture parity, static analysis, and all 34 tests passed. Coverage includes link opening and copying, launch failures, direct field focus, field-level edits, cancel, and conflict drafts |
| Android instrumentation | All 46 tests passed on a disposable Android 15 / API 35 x86_64 emulator, including data-only web intents, protected and invalid URL rejection, missing handlers, and the existing account, offline original, and notification regressions |
| Builds and lint | Default and loopback-mock x86_64 debug APK builds passed. Android lint reported zero errors and eight warnings |
| Emulator links | Opened an original from a pending local share in Chrome and returned to the same ITDA details with Android Back. With networking disabled, a recommendation opened its URL in Chrome and Back preserved the details scroll position |
| Emulator editing with the mock API | Title and empty-note taps focused the corresponding fields. Opening the original from the editor and returning kept the title draft. The mock confirmed separate versioned saves with the original URL intact, and the library showed the updated title |

Instagram and YouTube URLs were exercised through the Android intent tests.
Emulator testing used Chrome for the actual external handoff. Physical device
verification remains outstanding.

### Phase A7.1 Android checks

A7.1 starts from main at `2a99485`, which includes the merged A6.2 PR #8.
The tray projects the existing library through a bounded Box2D scene.
See the [tray decision](decisions/0008-android-rigid-pebble-tray.md).

| Check | Result |
| --- | --- |
| Flutter | Locked dependency resolution, fixture parity, static analysis, and all 46 tests passed. Tests cover staggered release, collision and sleep, drag, reduced motion, account switching, stable receipt identity, archive transitions and version conflicts |
| Android instrumentation | All 46 tests passed against the final default APK on the disposable emulator. The suite covers Android receipt, external links, sync, notification lifecycle and transport, upload retries, and staging configuration |
| Android builds and lint | The default arm64-v8a, armeabi-v7a, and x86_64 debug APK and the x86_64 loopback mock APK built successfully. Android lint reported zero errors and eight warnings. The APKs contain the SUIT weights and the SUIT and Box2D notices |
| Host physics | With 500 candidate identities, the three viewport fixtures simulated 10, 6, and 4 bodies. They slept after 166, 133, and 186 steps, respectively. The mean step costs were 12.1, 8.2, and 5.2 microseconds on the Windows test host |
| Emulator UI | Captured the empty tray, cascade, settled light and dark trays, archive, and detail on a disposable Android 15 / API 35 x86_64 emulator. Returning from details preserved all five settled positions. The tray was also captured at 760 px wide with Android font scale 1.8 |
| Emulator workflow with the mock API | Completion, drag to archive, and return to pending each received a new version. The source, edits, analysis, and notification visibility and generation stayed intact. A new native share appeared alongside the five existing items and produced one acknowledged mock record |

The host timings cover simulation steps. Mobile frame timing, physical-device
testing, and live workflow verification remain open. Long titles can truncate
sharply on narrow pebbles. The collection and details expose the individual
items outside the tray.

## Next concrete tasks

### Developer A — Mobile

1. With B and C, verify ingestion, private uploads, notification mutations,
   edits, and durable sync in staging with two Supabase identities. Exercise
   concurrent bootstrap writes, page interruption, cursor expiry and conflicts.
2. Agree with B on FCM device registration, revocation and dispatch. Connect
   delivery hints to the authoritative refresh path and exercise delayed,
   duplicate and cross-account delivery.
3. Measure a full tray on lower-end Android devices and refine long labels and
   the archive drop target using those device checks.

### Developer B — Backend and AI

1. Implement verified Supabase JWT authentication and owner-filtered DB repository;
   retain safe default behavior and two-identity negative tests.
2. Commit ingestion, asset attachment, job, sync event and idempotency receipt in
   one transaction. Implement conditional updates and conflict mapping.
3. Implement private upload completion verification and URL/document extraction
   defenses before accepting live content. Preserve raw originals on failure.
   Provide owner-checked private download capabilities and review a way to
   preserve original share subjects separately from user-edited titles.
4. Implement PostgreSQL job claims, leases, retries, bounded LLM adapters, validated
   coverage/results and atomic persistence. Then design durable FCM dispatch with A.

### Developer C — Web and Data

1. Repeat reset, pgTAP and lint on the disposable Supabase stack with Docker.
2. Connect the web client to B's persistent Supabase/FastAPI adapter and test
   two real identities, private objects, and simultaneous Android/web edits.
3. Validate cursor expiry and full resync with B's retention policy. Review
   cross-library search with A and B before adding a shared API operation.
4. Configure Vercel after the real adapters and integration checks are ready.

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
