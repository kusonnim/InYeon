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

## Architecture review of the full flow

| Transition | Available evidence | Real integration still required |
| --- | --- | --- |
| Android share -> local persistence | Native receiver, atomic private copy and outbox receipt, Flutter pending list | Broader Android version and provider coverage |
| Local persistence -> API | Android account-bound outbox, Supabase session client, content and private asset requests verified with a contract mock | Live Supabase JWT verification, durable idempotent ingestion and verified private storage |
| API -> DB + job | Migrations, relationships, constraints, repository semantics | Atomic DB adapter, idempotency receipts, concurrency tests |
| Job -> extraction -> summary/recommendations | Worker stages and coverage fixtures | Job claims/leases, real extraction, hosted model |
| AI result -> persistence | Distinct source/generated/edit fields and failure tests | Transactional guarded writes and retry recovery |
| Result -> notification update | Android presentation and local suppression, contract mock refresh and mutations | Owner-scoped live detail/edit and notification transactions, device registration, durable dispatch and FCM |
| Persisted content -> mobile and web libraries | Android persists owner-scoped snapshots and page checkpoints against the contract mock. Backend sync models and SQL sequence allocation exist | Live authenticated catalog and feed adapters, two-account bootstrap/expiry/reconnect, web synchronization |

This review establishes architectural feasibility, not a running Android-to-web
system. Executed local evidence is listed in STATUS and must not be inferred from
the existence of a test file or a configured CI job.

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
