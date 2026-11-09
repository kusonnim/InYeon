# Phase 0 onboarding audit

Date: 2026-11-09. Method: a fresh reviewer was given only the repository path and
the acceptance questions, with no conversation history or original planning text.
The reviewer read the documentation and checked corresponding code/contracts.
This was a documentation/code review, not an additional runtime test execution.

## Actual gaps found and corrected

1. **Contradictory retry retention:** the contract README initially specified at
   least seven days, while the data guide and STATUS said lifetime of effect. The
   contract now uses lifetime of effect until a reviewed safe bounded-retention
   policy exists. A new agent must not silently delete receipts and re-enable duplicates.
2. **Overstated client integration:** INTEGRATION initially claimed a client create
   model and sync interface as Phase 0 evidence. Inspection showed both client
   abstractions only expose list/get/update. The evidence table now states that
   create/sync schemas exist in the backend, and client transports/types remain work.
3. **Ambiguous data relationships:** architecture wording initially implied every
   child identifier had a foreign key. It now explicitly documents why sync
   tombstone identifiers lack FKs and require server ownership validation.

A separate contract review also found that recommendation sync events lacked the
parent content ID needed for a detail refetch. `SyncEvent.content_id` was added to
the API and SQL contract. This is distinct from implementing client sync.

## Acceptance questions and repository evidence

| Question | Where a new agent gets an accurate answer |
| --- | --- |
| What is ITDA and why use it? | [PRODUCT: identity and problem](PRODUCT.md#identity-and-problem) explains forgotten saves and contextual next steps |
| What happens after sharing? | [Primary journey](PRODUCT.md#confirmed-primary-journey) covers durable receipt, prompt close, async processing and sync, explicitly as target behavior |
| What does AI produce? | [Analysis policy](PRODUCT.md#analysis-and-recommendation-policy) defines grounded summaries, accessible-source coverage and optional recommendation kinds |
| Why is this not a to-do app? | PRODUCT explains that a saved item creates no obligation and zero recommendations is valid |
| How do components communicate? | [ARCHITECTURE](ARCHITECTURE.md) and [INTEGRATION](INTEGRATION.md) separate target flow, API boundaries, fixtures and missing adapters |
| What must never change accidentally? | [AGENTS](../AGENTS.md#non-negotiable-behavior) and PRODUCT cover privacy, source grounding, independent states, suppression and explicit restoration |
| What should each owner modify? | [OWNERSHIP](OWNERSHIP.md) identifies A/mobile, B/backend+AI, C/web+data and shared review boundaries |
| Which contracts are authoritative? | AGENTS identifies PRODUCT, [OpenAPI](../contracts/openapi.yaml), migrations and ADRs, with coordinated schema/fixture/test updates |
| What exists and what is next? | [STATUS](STATUS.md) lists concrete implementation, verification limits and the next tasks per owner; code confirms fixture-only clients and fail-closed real API adapters |

All acceptance questions were answerable after these corrections. The reviewer
checked 18 existing Markdown files and 27 relative file-link targets; none were
missing. CI working directories and commands mapped to existing entry points.
Flutter analysis/tests are not an Android build, and a SQL parse is not live RLS
execution. These distinctions remain explicit in STATUS. The newly added audit
record does not supersede implementation status or make pending integrations complete.
