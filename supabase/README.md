# Data foundation

Developer C owns migrations; Developer B reviews API and worker implications. Read
the root `AGENTS.md`, `docs/OWNERSHIP.md`, and `contracts/openapi.yaml` first.
Migrations are the authoritative persisted schema. The OpenAPI contract is the
authoritative HTTP shape; normalized records are assembled into that shape by
the future database adapter.

## What exists

- `202611090001_foundation.sql`: twelve tables, constraints, indexes, ownership
  policies, and the private `content-assets` bucket.
- `202611090002_notification_transitions.sql`: server-only reference functions
  for notification dismissal/restoration and commit-ordered synchronization.
- `tests/database/foundation.test.sql`: 33 pgTAP assertions covering ownership,
  forbidden writes, cross-owner references, notification transitions, source
  preservation, generated recommendation acceptance, and private object RLS.
- `config.toml`: local Supabase configuration; it has no remote project binding.
- `verify_contract.py`: static mapping/enum checks between nine HTTP schemas and
  the normalized SQL schema, including explicitly derived response fields.

This is not a deployed database integration. The FastAPI fixture repository does
not call these functions. JWT verification, API database transactions, byte
uploads, worker claim/retry logic, and FCM delivery remain implementation work.

## Local verification

Install the Supabase CLI and run a Docker-compatible container runtime. From the
repository root, against the disposable local stack only:

```sh
supabase start
supabase db reset
supabase test db
supabase db lint --level error
```

`db reset` recreates the local database. Never add `--linked` or a production URL
to the test/reset commands. Schema SQL requires Supabase's `auth` and `storage`
schemas; it is not intended for an empty vanilla PostgreSQL database.

During initial authoring, Docker CLI was present but its Linux engine was not
running; Supabase CLI and `psql` were absent. Therefore the pgTAP suite and live
RLS/storage behavior were not executed locally. See `docs/STATUS.md` for any
subsequent verification and CI results. A successful static SQL parse is not a
database execution or an authorization test.

Static verification did pass during authoring: pglast 8.7 parsed all SQL statements
in both migrations and the test file, plus all four PL/pgSQL function bodies. The
HTTP/SQL mapping check passed for nine models and twelve owned tables. To rerun the
mapping check, use the backend development Python environment from repository root:

```powershell
.\services\backend\.venv\Scripts\python.exe supabase\verify_contract.py
```

On macOS/Linux use `services/backend/.venv/bin/python` instead.

## Ownership and access

| Tables | Client access | Server responsibility |
| --- | --- | --- |
| `preferences`, `contents`, `content_assets`, `analyses`, `recommendations`, `feedback_events`, `notification_states`, `sync_events` | Authenticated SELECT of `user_id = auth.uid()` rows only | All writes through authenticated API or trusted worker |
| `analysis_jobs`, `sync_heads`, `idempotency_records` | None | Worker queue, sync sequencing, retry replay |
| `client_devices` | None, including push tokens | Future authenticated device registration/revocation API |
| `storage.objects` in `content-assets` | Owner-only verified object reads; no direct write policy | Issue object-specific upload/download capabilities after ownership checks |

Every application table has RLS. The API and worker use a privileged server
credential, which bypasses RLS: each query must also constrain the verified JWT
subject or trusted job's owner. A client-supplied `user_id` is never authority.
Composite `(content_id, user_id)` foreign keys prevent cross-tenant child links;
recommendation feedback additionally binds the recommendation to that content.
Public roles have no execute permission on transition/sync helper functions.

## Representation and provenance

- `contents` stores the original `source_text`/`source_url`, user-editable `title`
  and `user_note`, plus independent analysis/workflow status and `version`.
- `analyses` stores the current analysis, its actual `coverage`, grounded summary,
  and limitations. Only one current analysis per content is supported in Phase 0;
  versioned analysis history requires a reviewed migration.
- `recommendations.text`/`source_url` retain generated output;
  `user_text` holds a correction. `accepted` starts false. Creating generated
  output must never create an acceptance feedback event.
- `content_assets.content_id` is nullable while uploading. API `asset_ids` is
  assembled from attached, verified (`ready`) assets. `analysis_id` and `user_id`
  on recommendations/analyses are internal provenance and ownership fields.
- SQL `timestamptz` stores instants; the API serializes them as UTC ISO 8601.
  Integer versions and revisions must be incremented by every relevant write.
  HTTP version conflicts are handled by the future adapter's conditional updates.

## Required transaction boundaries

These rules are an implementation contract, not a claim that the adapter exists.

1. Verify the bearer JWT, including issuer/audience/signature/expiry, and derive
   the owner. Do not accept a service credential from a client.
2. For each owner mutation transaction, call `lock_sync_head(owner)` **before**
   locking entity rows. Use this lock order throughout API and worker paths.
3. For ingestion/events/restore, check the unique idempotency tuple
   `(user_id, operation, idempotency_key)` before checking current versions. Replay
   its original status/body for the same request hash; reject changed payloads.
   Operation includes the route target where relevant. Retain records for the
   lifetime of their effect in Phase 0; deleting them can re-enable duplicates.
4. Ingestion must attach only ready owner assets, insert content and its initial
   notification state, enqueue the unique analysis job, append sync events, and
   save the replay record in one transaction. Acknowledge only after commit.
   Image/document ingestion must reject empty or wrongly typed asset lists.
5. User edits use `WHERE user_id = owner AND version = expected_version` and
   increment version once. A zero-row update requires an ownership-safe 404 or a
   structured 409. Recommendation acceptance/correction and its explicit feedback
   event belong to the same transaction.
6. Worker claim should use a short transaction with `FOR UPDATE SKIP LOCKED` and
   a lease (`locked_at`, `locked_by`), then perform inference outside that
   transaction. Result persistence must atomically preserve user edits, update
   source coverage/status, save recommendations, finish the job, and append sync.
   A failure retains the original content and sets analysis status independently.
7. `append_sync_event` increments the owner head while its lock remains held
   through commit. Read events ordered by `(user_id, sequence)`. A bare global
   sequence is insufficient because transactions can commit out of order.
   The API signs/binds opaque cursors to the owner. `delete` events are tombstones;
   deletion endpoints and sync retention/resnapshot rules are not yet implemented.
   Events include `content_id` so clients can fetch a recommendation's parent;
   only preference events have no parent. Entity/parent IDs deliberately have no
   foreign key because tombstones must survive deletion. The server must validate
   ownership before writing events. `append_sync_event` accepts the parent's UUID
   as its fifth argument for recommendation events, and derives it for content
   and notification events.

## Notification state contract

`generation` identifies an explicitly restored notification lifetime; `revision`
identifies state changes and never resets. Initial state is active, generation 1,
revision 1. Dismissal changes visibility and revision only. Restoration from a
dismissed state increments both. Matching already-active restoration and
already-dismissed dismissal are no-ops. Delayed dismissals from an older generation
return `applied: false, reason: stale_generation`; they cannot hide a newer one.
Other generation/revision mismatches raise `notification_conflict`, which the
adapter maps to HTTP 409 with the current generation/revision.

The SQL helpers implement these transitions and sync writes, but the future API
must add authentication and idempotency replay around them. Neither helper alters
`workflow_status`. AI completion, sync, startup, and retries must not call restore.
FCM is a wake-up hint; mobile must reconcile the current server state plus its
durable pending local dismissal before showing/updating anything. A persisted
device/generation delivery marker is still needed for one automatic notification;
multi-device notification delivery policy remains a team decision.

## Private asset lifecycle

The proposed MVP allowlist is JPEG, PNG, WebP, PDF, and plain text, up to 20 MiB.
The API generates both asset UUID and exact object path
`{user_id}/{asset_id}/source`; filenames never determine object paths. It stores
the expected size, media type, lowercase SHA-256, and capability expiry first.
It issues a Supabase signed upload URL with overwrite disabled. Supabase signed
upload URLs are valid for two hours; an application timeout does not revoke a
still-valid capability. URLs/tokens must not appear in logs, content, or sync data.

Completion must verify actual object bytes, size, MIME, and hash before marking
`ready`; client metadata alone is insufficient. Later ingestion attaches the
asset. Download capability issuance also verifies owner and ready status. Failed
or abandoned pending assets need a future cleanup worker using the Storage API;
deleting database metadata does not delete underlying object bytes. File scanning,
retention, provider data handling, quotas, and safe extraction are deployment
decisions still to be finalized.

## Sources

The implementation follows Supabase's official
[RLS and storage access model](https://supabase.com/docs/guides/storage/security/access-control),
[signed upload capability behavior](https://supabase.com/docs/reference/python/storage-from-createsigneduploadurl),
and [pgTAP test workflow](https://supabase.com/docs/guides/database/testing).
