# ADR 0007 — Isolated Android staging installation

Accepted for Phase A6 on 2026-11-10.

## Context

Android already binds durable receipts, sessions, notification suppression
and library checkpoints to an API realm and Supabase user. Staging tests also
need a clear share target and a separate Android data directory so they can run
alongside an existing install.

## Decision

Add a debug-only staging build mode with the application ID
`com.itda.itda_mobile.staging` and the launcher and share label **ITDA Staging**.
Accept a separate staging set of API, Supabase Auth and publishable key settings.
Validate them before building and check the destination again in the native
client. The staging and live builds use a cleartext-denying network policy.
The debug loopback policy remains available for the mock and local instrumentation.
The mode and both bases remain part of the existing API-realm calculation.
The Account screen exposes the staging API hostname before sign-in.

Continue using the existing Supabase session client, Android Keystore vault and
WorkManager operations. Test users enter their credentials after installation.
The A6 preflight probes process health and unauthorized responses with sanitized
output. Staging acceptance needs authenticated checks with two real users.

## Consequences

The staged APK coexists with the regular app, with separate local originals,
work queues, caches, Keystore entries and notification settings. A new install
starts with its own empty local inbox. Within staging, changing the API or Auth
base creates a new realm, so assigned data remains scoped to its original
destination. The build validates the explicit inputs. Approval of the matching
staging API and Supabase project remains a deployment handoff requirement.

See the [staging runbook](../../apps/mobile/STAGING.md) and
[integration handoff](../INTEGRATION.md#phase-a6-staging-handoff).
