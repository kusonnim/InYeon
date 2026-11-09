# 0004 Android outbox ownership and delivery

Status is accepted for the Phase A2 mobile implementation.

## Context

Android accepts shares before network or authentication work. Phase A1 receipts
already have a stable client event ID and may predate the first sign-in. A
process can stop after a remote operation commits and before the app sees its
response. Each operation needs a durable identity and an ownership boundary.

## Decision

- Keep the A1 source directory and receipt intact. Add an atomic outbox sidecar
  for owner, status, operation keys, verified asset ID, and acknowledged content ID.
- Bind a new share to the locally signed-in user and configured destination.
  A share received without an account requires explicit assignment after sign-in.
  Once assigned, the owner and destination are immutable. Other accounts see
  a redacted row and cannot submit it.
- Keep Supabase tokens in a device-private vault encrypted with an Android
  Keystore key. Serialize refreshes, verify the token subject against the session
  user, and install a refreshed session only while its prior session is current.
  The API remains responsible for JWT signature verification and ownership.
- Enqueue unique, network-constrained WorkManager work for each assigned receipt.
  Retry the same content body with the receipt's client event ID. Use separate
  persisted keys for reservation and completion. Replace an expired, unverified
  reservation with new asset operation keys. Replay a verified asset ID with the
  original content request across lost responses.
- Keep capability URLs and headers in memory. Replay a live reservation to
  obtain its capability after interruption. Record successful completion before
  creating content and record the server acknowledgment before showing synchronized.

## Consequences

The receiver still requires only local storage to accept a share. Account recovery
and retries can run with Flutter closed once work is enqueued. A failed scheduler
write leaves a local receipt for the next launcher recovery. Android may defer work
and an OS force-stop can suspend it until the app starts again. Retention of local
originals and server-side cleanup of unused reservations remain separate decisions.

The upload client uses the existing API contract. A live rollout requires B's
authenticated idempotent ingestion and verified asset endpoints plus C's private
storage and ownership checks. The loopback mock verifies the client's behavior
with synthetic accounts.
