# ADR 0003: API contracts, private objects, and trusted mutations

Status: Accepted foundation choice; adapter implementation pending. Date: 2026-11-09.

## Context

Separate clients and developers must agree on fields and conflict semantics. Direct
table writes could bypass idempotency, version checks, analysis provenance, sync
events, and notification suppression.

## Decision

`contracts/openapi.yaml` is the wire authority. Migrations define storage and RLS;
an explicit adapter assembles nested API objects. Clients authenticate through
Supabase and submit mutations through FastAPI. Owner-only database reads remain
protected by RLS; ordinary clients cannot write tables directly. Sensitive queues,
device tokens and idempotency records are server-only.

Keep upload objects private. The API chooses the path and grants temporary
capabilities only after authentication/ownership checks. Complete upload verification
precedes attachment to a content item. Never accept a public URL as proof of ownership.

Allocate per-user sync positions under an owner-row transaction lock. Commit content
mutations and sync events atomically; do not use commit-unsafe global sequence
ordering as a polling high-water mark. Treat idempotency keys as scoped to verified
owner and operation, and reject changed-body replays.

## Consequences

The server must enforce ownership even when using privileged credentials that
bypass RLS. Deployment cannot proceed with fixture auth or in-memory repositories.
The team must agree on retention/cleanup, upload limits, JWT strategy, and cursor
expiry policy before enabling real data. See STATUS for specific open decisions.
