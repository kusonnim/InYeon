# Integration contract and checkpoints

## Common boundary

Mobile and web consume [OpenAPI](../contracts/openapi.yaml), never a worker's internal
models or raw privileged database interface. The canonical catalog and event/error
examples live in `contracts/examples/`. Web imports the catalog; Flutter packages a
copy checked by `dart run tool/sync_fixtures.dart --check`. Python contract checks
validate schemas and fixtures. Update all consumers in a shared contract PR.

The Android share and notification outboxes use bearer tokens from a Supabase
user session. The catalog fixture mode and loopback contract mock use synthetic
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
5. **Notification/sync milestone:** Phase A3 persists Android dismissals, uses
   versioned restore, and refreshes authoritative content through the existing
   GET endpoint. B and A agree on device registration and dispatch. C integrates
   cursor sync and editing conflicts. Run delayed and duplicate FCM tests once
   the delivery adapter is available.
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
| Persisted content -> PC web sync | Backend sync endpoint/model and SQL sequence helper | Client sync models/transport, authenticated incremental sync, reconnect/full resync |

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
8. Poll paginated sync while concurrent writes commit. Confirm all changes arrive,
   duplicates are harmless, and cursor storage occurs only after local application.
   Exercise expired cursor/full resync once retention is implemented.
9. As user B, request user A's content/recommendation/asset and attempt direct table
   writes. Assert API denial, RLS isolation, no private download, and no service key
   in either bundle. Exercise uncompleted/wrong-owner assets and expired capabilities.
10. Verify notification body opens the correct details and Edit is the only quick
    action. Verify denied notification permission leaves saved library data intact.

Record command/build/device versions, assertions, failures, and remaining limitations
in STATUS. Full E2E completion requires actual OS and real adapter execution.

## Phase A3 live dependencies

- Developer B supplies Supabase JWT verification and owner-scoped durable
  `GET/PATCH /v1/contents/{id}`, `POST /v1/notification-events`, and
  `POST /v1/contents/{id}/notification/restore`. Mutations need the documented
  conflict fields and idempotency semantics across process restarts. Live share
  registration and private assets also depend on the A2 server adapters.
- Developer C applies the existing migrations on disposable Supabase and
  verifies notification visibility, owner isolation, RLS, and private object
  access using two identities. Web sync must retain content after dismissal.
- Developers A and B agree on device registration, revocation and FCM dispatch.
  A delivery hint should trigger the current authenticated content read.
  Phase A3 refreshes after registration, on app resume, or on user request.
