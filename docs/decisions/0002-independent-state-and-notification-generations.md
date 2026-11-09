# ADR 0002: Independent states and notification generations

Status: Accepted. Date: 2026-11-09.

## Context

Dismissal is a presentation choice. Analysis completion is processing progress.
Content completion is an explicit workflow choice. Offline events can arrive after
a notification has been deliberately restored.

## Decision

Keep `analysis_status`, `workflow_status`, and notification visibility independent.
Track notification generation separately from revision. Only explicit restoration
advances generation. A dismissal for an older generation cannot modify the newer
one. Conditional edits and idempotent event processing prevent lost edits and retries
from multiplying transitions. Generated recommendations start unaccepted.

## Consequences

Clients must persist suppression locally and reconcile state before posting a
notification. They cannot infer acceptance from generation, or completion from
dismissal. FCM payloads cannot be authoritative commands to resurrect a notification.
Multi-device delivery policy still needs a separate decision.
