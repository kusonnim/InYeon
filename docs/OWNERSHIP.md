# Ownership and coordination

| Owner | Primary code boundary | Responsibilities | First work |
| --- | --- | --- | --- |
| Developer A | `apps/mobile/` | Flutter, Kotlin share integration, local outbox, upload, native notifications, details/editing | Durable Android receipt and outbox, then authenticated upload |
| Developer B | `services/backend/` | FastAPI, auth/ownership, ingestion, jobs, extraction, summaries, recommendations, worker | Real Supabase JWT/repository adapters and atomic ingestion |
| Developer C | `apps/web/`, `supabase/` | Web library, schema/RLS/private storage, shared UI conventions, integration support | Execute database/RLS tests, then authenticated web integration |

`contracts/` and state meanings are shared. B stewards API implementation, C
stewards migrations, and A validates Android delivery/retry feasibility. All three
must review incompatible interface changes. A code owner may implement a shared
change only after coordination; ownership does not give permission to redefine it.

## Contribution rules

1. Read root `AGENTS.md`, `STATUS.md`, and relevant module guidance.
2. Use a feature branch and keep the change within the assigned boundary.
3. Before crossing a boundary, state the required change to its owner in the PR or
   team discussion. If identities are not configured, request the relevant role's
   review manually. Do not invent GitHub handles in CODEOWNERS.
4. For wire or data changes, update OpenAPI, examples, all affected language
   models, migrations, tests, and documentation in the same coordinated PR.
5. Record major architecture/contract changes in a new ADR. Supersede old decisions
   explicitly. Do not edit already-applied migrations to change deployed schema.
6. Run affected checks and report unavailable tools honestly. Update STATUS after
   meaningful progress and list both executable evidence and remaining work.
7. Resolve conflicting shared edits before merge; do not force-push over another
   contributor's work. Require PR review and passing checks on stable `main`.

Repository branch protection and actual review assignments must be configured by
the GitHub repository administrator. A template or workflow file does not enable them.

## Parallel development

A and C can use the same synthetic fixture catalog with no live worker or database.
B can implement adapters against the versioned contract without changing client
screens. C can evolve the physical schema while preserving API representations;
document every explicit mapping rather than expecting clients to know SQL tables.
Use [INTEGRATION](INTEGRATION.md) checkpoints to replace one adapter at a time.

Common UI language: saved items are **content**; suggestions are **recommendations**;
completed/archived are workflow states; dismissed is only a notification state.
An AI result is labeled as generated; user corrections are separately represented.
