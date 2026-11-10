# Android staging integration runbook

## Inputs and build

Obtain the approved HTTPS API base, its matching Supabase Auth base and
publishable key, two disposable email/password accounts, and the corresponding
web URL from Developers B and C. Record the API deployment revision and the
migrations applied to the staging database. Use synthetic sources and files
throughout the run. The staging and production services must use separate data
and Auth projects or a team-verified isolation boundary.

In a clean build shell set the staging variables below, substituting the approved
values. The domains shown are placeholders. The APK embeds the mode, endpoints
and publishable key. Enter account passwords interactively in the app.

```sh
export ITDA_UPLOAD_MODE=staging
export ITDA_STAGING_API_BASE_URL=https://api.staging.example.test
export ITDA_STAGING_SUPABASE_URL=https://auth.staging.example.test
export ITDA_STAGING_SUPABASE_PUBLISHABLE_KEY='<staging publishable key>'
python apps/mobile/tool/staging_preflight.py
cd apps/mobile
flutter pub get --enforce-lockfile
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Use `$env:NAME = 'value'` in PowerShell. Keep the generic `ITDA_API_BASE_URL`,
`ITDA_SUPABASE_URL`, and `ITDA_SUPABASE_PUBLISHABLE_KEY` settings out of the
staging build shell. The preflight sends only HTTPS GETs to the configured API,
uses normal TLS verification, and refuses redirects. It reports process health
and expected unauthorized responses for missing credentials and a synthetic
invalid token. Its result is independent of authenticated adapter and database
verification. A health response with `unconfigured` is an advisory, and a fixture
response or a bearer-gate mismatch fails the check.

Select **ITDA Staging** in the launcher and Android share sheet. Check **Staging
mode** and the API host under **Account** before using either account. Confirm
`adb shell pm path com.itda.itda_mobile.staging` identifies the isolated install.
Its storage, Keystore session, work queues and notification permissions are scoped
to that package. Switching packages does not migrate any local data. A changed
API or Auth base also changes the realm within that package. Android's network
policy blocks cleartext traffic for staging and live builds.
[Android build variants](https://developer.android.com/build/build-variants)
[Android network security configuration](https://developer.android.com/privacy-and-security/security-config)

## Acceptance cases

Use approved disposable infrastructure for the fault cases. Coordinate expiry,
delayed response, process-restart and deletion controls with B and C. Record each
case as passed, failed, or blocked, with the observed response or device state.

| Area | Procedure and expected evidence |
| --- | --- |
| Login and renewal | Sign in as A and verify the API returns A's data. Run another request after access-token expiry with a valid refresh session. Revoke or invalidate the test refresh session and verify re-authentication is required and local originals survive. Sign in as B and verify A's assigned originals, server snapshots, and notifications are inaccessible. |
| Offline receipt and assignment | Share synthetic text and an approved synthetic URL in airplane mode. Verify the sender returns after the durable receipt and both originals reopen after stopping ITDA. Assign a receipt saved while signed out only after confirming the displayed account. Reconnect and verify durable content IDs and one card per server item. |
| Private image and PDF | Share synthetic JPEG/PNG and PDF samples. Observe reservation, capability PUT and completion before content creation. B verifies the owned object, stored size, MIME signature and hash. As B, verify A's object cannot be listed, downloaded, completed or attached. Verify an unauthenticated read fails. |
| Upload recovery | Interrupt a PUT and expire a reservation with the approved fault setup. Check re-reservation of an expired, unverified asset and reuse of a verified asset during content retry. Drop the response after commit, restart Android, and verify a retry with the same key returns the same content ID. Confirm one server item, one job, one initial notification and preserved local bytes. |
| Content and sync | Use a catalog larger than a page and read the feed at a small limit. After the first catalog page is captured, create a newer item, edit another and delete a synthetic item through B/C's staging procedure. Verify catch-up, replay, a structured expired-cursor error, and atomic replacement. Interrupt an incremental read and relaunch offline. Verify the prior checkpoint, then reconnect and confirm the change appears once. A deleted server card leaves any original local share intact. |
| Editing and web consistency | Open an Android draft and edit the same version from the signed-in web library. Expect `409 version_conflict` with the current version. Review the server version and confirm the draft is kept until the user deliberately saves or discards it. Compare the final state, visible items and owner on both clients. |
| Notification lifecycle | Grant permission and check initial eligibility and in-place analysis update. Swipe offline, restart, reconnect, and verify persisted dismissal leaves workflow and library membership unchanged. Restore explicitly, then submit a delayed dismissal for the prior generation. The new generation remains active. Repeat with a second account and with notifications denied. Record any OS shade versus server-state race and its ordering. |

## Sanitized diagnostics

Record the run date, Android version/API level, emulator or physical device,
APK mode and app revision, deployed API revision/version, and applied migration
IDs. Refer to accounts as A and B. Save HTTP method, route template, status,
documented error code, counts and state transitions. Keep JWTs, passwords, signed
URLs, response bodies, raw cursor values, account addresses and private content
out of artifacts. For Android transport troubleshooting, the `ITDAOutbox` debug
tag reports the HTTP method and exception class. Capture only that tag and omit
auth screens and full network traces.

These examples use synthetic content. Substitute A or B's current access token
only in the authorized test client, then record a redacted request template.

```http
GET /v1/contents?limit=1

GET /v1/contents?limit=1
Authorization: Bearer itda-a6-invalid-probe

POST /v1/contents
Authorization: Bearer <A>
Idempotency-Key: a6-synthetic-replay-01
Content-Type: application/json

{"input_type":"text","source_text":"A6 synthetic receipt"}

GET /v1/contents/<A-created-content-id>
Authorization: Bearer <B>
```

Expect structured `401 unauthorized` for the first two requests. A production
scaffold returns `501 adapter_not_implemented` for the synthetic invalid bearer
after recognizing the header. With authenticated adapters, the create and
exact replay return `201` and the same content ID, changed input under that key
returns `409 idempotency_conflict`, and B's read returns `404 not_found`.
Use a fresh key for a separate run. For cursor expiry, reuse a server-issued
cursor after the agreed retention or expiry control and expect
`400 invalid_cursor`. The OpenAPI contract has no client deletion endpoint.

Report infrastructure blockers and unmet assertions in
[STATUS](../../docs/STATUS.md#phase-a6-real-staging-evidence) and route them using
the [B/C handoff](../../docs/INTEGRATION.md#phase-a6-staging-handoff).
