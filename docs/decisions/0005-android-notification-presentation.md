# ADR 0005 — Durable Android notification presentation

Status: Accepted for the Phase A3 mobile implementation. Date: 2026-11-10.

## Context

Android owns the notification shade. The server owns visibility, generation,
and revision. The device can receive a user dismissal while offline and
receive older API responses after that dismissal. A2 already persists the
authenticated owner and server content ID for each acknowledged share.

## Decision

Use one stable Android tag and integer ID per API realm, user, and content ID.
Assign a generation-specific, immutable delete intent to each card. Use one
native controller to serialize durable state and presentation within the app
process. Store a generation suppression marker and its pending dismissal in one
atomic file replacement before enqueuing authenticated WorkManager delivery.
The persisted idempotency key and body survive retries. A conflicting dismissal
can use a newer revision of the same generation after a fresh read. A conflicting
restore requires another explicit tap.

Read the authoritative content after registration and after a successful
notification mutation. An idempotency replay can contain an earlier active
snapshot. Reconcile the latest generation and revision with local suppression
before showing any card. Only an authoritative new active generation is
eligible for a fresh post after a prior issuance. Update analysis in place
while Android still lists the card for that generation.

Write the issuance marker before the first platform post for a generation.
Account changes cancel the previous account's cards locally. Generation
markers survive account changes. The original account resumes its own events
and can restore a confirmed dismissal in the app.

## Consequences

The gap between committing issuance and Android accepting the post can leave a
generation with no visible card. A card cleared by Android or by account
cleanup stays absent for that generation. If Android removes a card but its
delete receiver cannot commit, the issuance marker still prevents another
automatic post and the device may lack a dismissal event to synchronize.

Android exposes separate active-card lookup and notification update calls.
The controller rechecks immediately before updating, and a delivered delete
intent persists suppression and cancels the tag. A swipe racing between
those platform calls can briefly show the in-flight update until the delete
callback reconciles it.

WorkManager resumes queued mutations after process death and reconnect. A
process interrupted between the local commit and WorkManager enqueue recovers
the event at the next launch or matching sign-in. Background delivery hints
and multi-device delivery policy remain integration decisions with Developer B.

Phase A4 builds the Android notification before the last active-card lookup,
which shortens the window between that lookup and the update call. The same
generation, issuance, and suppression rules apply.
