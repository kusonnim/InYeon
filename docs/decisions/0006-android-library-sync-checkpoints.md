# ADR 0006 — Android library synchronization checkpoints

Accepted for Phase A5 on 2026-11-10.

## Context

The mobile catalog needs to survive process death and work offline. A1/A2
already own durable source receipts and upload acknowledgments, and A3 owns
notification suppression. The server supplies a change feed and a separate
newest-first keyset catalog. The two reads do not share a snapshot token.

## Decision

Store a separate SQLite database per API realm and Supabase user in Android's
app-private, no-backup directory. Keep the original receipt, upload checkpoints,
and notification records in their existing stores. Create schema version 1
on demand. The A4 catalog was in memory and needs no migration.

For incremental sync, resolve the entities in a feed page through the
authenticated API. Apply changes and the exact next cursor in the same SQLite
transaction. Store the maximum applied sequence as decimal text to discard
replays without parsing the cursor. Content deletion writes a tombstone.
Recommendation and notification changes refresh the parent content. Preference
events update or clear the account's cached preferences.

For bootstrap, drain the retained feed to a boundary before traversing the
catalog. Stage the catalog and preferences in an inactive slot, then drain
events from that boundary into the slot. This includes writes that commit
while the catalog is being read, even when their list positions have already
passed. Publish the new slot and checkpoint together. After an interruption
or cursor expiry, the next rebuild clears and restages the inactive slot.
The previous complete snapshot stays visible until publication.

Use connected, unique WorkManager jobs with exponential backoff. A running job
can have one queued successor to cover a trigger that arrives after its last
server read. The Flutter UI reads cached data and requests work. Open drafts
use the existing version-checked editor. Notification refresh continues
through A3 with an authorized detail read and existing suppression rules.

## Consequences

A worker can recover incrementally at the last committed page. Bootstrap
may temporarily hold two snapshots and repeats its feed and catalog traversal
after interruption. Large histories may require evaluating retention and
bootstrap cost with the live adapters. Offline access requires a previously
published snapshot and the same installed account and realm. Derived cache
loss can be repaired by sync. Local originals and notification history are
independent of that recovery.

Live verification depends on owner-scoped, commit-ordered events, catalog
keyset stability, read-after-commit visibility, and structured cursor expiry.
See the [integration checklist](../INTEGRATION.md#android-live-dependencies).
