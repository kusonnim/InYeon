# ITDA mobile — Developer A

The Flutter app displays the synthetic catalog and shares saved on this Android
device. The native outbox can deliver assigned shares to a configured API.
Read the root [AGENTS.md](../../AGENTS.md), [product contract](../../docs/PRODUCT.md),
and [OpenAPI](../../contracts/openapi.yaml) before changing behavior.

## Run and verify

Install Flutter stable and the Android SDK. Use the JDK bundled with Android
Studio or a compatible JDK. Repository CI pins Flutter 3.47.9. The Android runner
and app dependency lockfile are checked in. Run from `apps/mobile` with an
Android emulator or device.

~~~sh
flutter pub get --enforce-lockfile
dart run tool/sync_fixtures.dart --check
flutter analyze
flutter test
flutter build apk --debug
flutter run -d <android-device-id>
~~~

After the APK build initializes the Gradle wrapper, run the native tests on a
disposable Android test device from `apps/mobile/android`.

~~~sh
./gradlew :app:connectedDebugAndroidTest
~~~

Use `gradlew.bat` on Windows. The suite exercises receipt persistence, stable keys,
file copying and hashing, interrupted receipt writes, and the HTTP upload
protocol with mock responses. Use a disposable installation for instrumentation.

## Android share receipt

Choose **ITDA** in the Android share sheet for plain text, an HTTP(S) URL, one
JPEG/PNG/WebP image, or one PDF. The native receiver displays progress while it
saves the share and returns to the sending app when Android finishes the activity.
Success displays **Saved on this device**. Unsupported input, unavailable files,
oversized payloads and write failures show an error. Files must be readable by the
provider during the share, including when the device is offline.

The receiver accepts `ACTION_SEND`. Text comes from `EXTRA_TEXT` or `ClipData` and is
preserved as received. A single HTTP(S) link in the text is also stored as the
source URL. File shares are limited to one attachment up to 20 MiB. The receiver
checks the leading file signature against the supported formats and preserves the
provider's reported MIME type when available. The local limit for text is 100,000
characters to match content creation. Source metadata can include subject, sender
package, declared MIME type, provider authority and display filename.

Open ITDA to see **Saved on this device** and each upload state. The section
refreshes on app resume and on native state changes. The separate **Sample
library** keeps the synthetic fixture list and details.

## Inbox and outbox

The app stores each share under `noBackupFilesDir/share-inbox-v1/<local_id>/`.
Each directory holds the immutable A1 `receipt.json` and, for a file share, the
copied source. The receipt stores the local ID, `client_event_id`, source type,
original and available metadata, and receipt timestamp. Attachment records
include the relative file reference, filename, MIME type, size and SHA-256.
Phase A2 writes mutable upload progress to a synced `outbox.json` beside the
receipt. A1 directories without a sidecar open as unassigned. Device backups
are disabled for the app.

The receiver streams `content://` data into a staging directory while its Android
read grant is available. It syncs the bytes and receipt metadata, then renames
the staging directory in the same inbox and syncs the parent directories before
returning success. The single rename publishes the original and its pending outbox
entry together. The next inbox operation cleans abandoned staging directories.
Failure before publication leaves no pending entry. A fully copied receipt
published just before process death can be recovered on the next inbox read.

An Android activity recreation reuses the delivery ID in saved instance state.
When the receipt already exists, the receiver uses it without reopening the
original URI or regenerating the retry key. Each fresh `ACTION_SEND` delivery gets
its own ID, including a deliberate repeat of the same content. Deduplication
across activity restarts relies on Android restoring the saved instance state.
An interrupted delivery whose original account is unknown waits for assignment.

## Share-sheet check

Launch ITDA on a disposable emulator or device. Share text and a page URL from a
browser, then share a PNG and a PDF from Files. Confirm ITDA closes and the
sending app returns after each receipt. Repeat with Wi-Fi and mobile data off.
Force-stop and reopen ITDA and confirm that all accepted shares still appear.
Delete the sender's test files and verify the private copies still exist.
Use the native suite above for controlled recreation, storage failure and
acknowledgment checks.

## Upload account and state

Use **Sign in** with a pre-existing Supabase email/password account. The
native client stores the access and refresh tokens in an Android Keystore
encrypted vault. It refreshes the session when the token is about to expire
or when an API request returns 401. Account sign-out clears the device session.
Tokens stay in native code and the app only exposes account labels to Flutter.
[Supabase session behavior](https://supabase.com/docs/guides/auth/sessions)

New shares are assigned to the active user and API destination when saved.
For A1 shares and shares received while signed out, select **Upload** and
confirm the displayed account for each item. Assigned receipts keep that user
and destination across account changes. Another account sees a redacted row.

| State | Behavior |
| --- | --- |
| Pending upload | An assigned item is queued for a connected network |
| Uploading | A worker is submitting or resuming the item |
| Waiting to retry | A temporary network, server, or local storage error delayed the attempt |
| Authentication required | The item needs assignment or a valid session for its original account |
| Synchronized | The matching server content ID was durably saved after a valid 201 acknowledgment |
| Upload failed | A permanent error ended automatic retries and kept the original |

WorkManager persists unique per-receipt work with a connected-network constraint.
Temporary failures use exponential backoff starting at 30 seconds, bounded by
WorkManager's five-hour maximum. The worker resumes stored checkpoints after
process death. Explicit sign-in wakes matching paused items. Android can defer
work and a force-stopped app resumes scheduling after the next launch.
[WorkManager retry and backoff behavior](https://developer.android.com/develop/background-work/background-tasks/persistent/getting-started/define-work)

Content creation uses the original `client_event_id` as `Idempotency-Key`.
Attachments use separate persisted reservation and completion keys. The worker
reserves a private upload, sends the local bytes using the supplied capability,
and checks the server's completion receipt before attaching the asset. A live
reservation can be replayed for its capability after interruption. Expired
unverified reservations use new asset keys. A verified asset and the content
request stay stable across content retries. Capabilities remain in memory.
The app retains local originals after synchronization.

## Configure an upload destination

`ContentApi` is the replaceable catalog interface. The default `ITDA_DATA_MODE` is
`fixture` and uses the synthetic catalog copied from `contracts/examples/catalog.json`.
Catalog mode is independent of native upload configuration.

Android reads the following environment variables at build time. The default
upload mode is `disabled`, which keeps sharing local. For `live`, configure
`ITDA_API_BASE_URL` and `ITDA_SUPABASE_URL` with HTTPS URLs and set
`ITDA_SUPABASE_PUBLISHABLE_KEY` to the project's `sb_publishable_` key.
The build accepts publishable keys only. Configure the matching real API and
Supabase project before live verification.

## Loopback contract mock

Run the mock from the repository root with Python and the `PyYAML` and
`jsonschema` packages installed. It validates the exercised API requests and
responses against OpenAPI. It uses synthetic users and in-memory state.

```sh
python apps/mobile/tool/mock_upload_server.py --expire-first-capability --hold-source-text A2_PROCESS_KILL
```

In a second shell, export the Android build variables below and run the app
on a disposable Android emulator. Use `$env:NAME = 'value'` in PowerShell.

```sh
export ITDA_UPLOAD_MODE=mock
export ITDA_API_BASE_URL=http://10.0.2.2:8782
export ITDA_SUPABASE_URL=http://10.0.2.2:8782
export ITDA_SUPABASE_PUBLISHABLE_KEY=sb_publishable_itda_mock
cd apps/mobile
flutter run -d <android-device-id>
```

Sign in with `a@example.test` or `b@example.test` and `itda-test-only`.
Mock mode is debug-only and restricts URLs to loopback or the Android emulator
host alias. Acknowledged mock items display **Synchronized (mock)**.
For the lost-acknowledgment check, send the synthetic text `A2_PROCESS_KILL` and
terminate the app process when the mock reports that it committed the request.
The retry should replay the receipt using the original key.

The [integration contract](../../docs/INTEGRATION.md) describes the dependencies
on the real JWT verifier, idempotent ingestion, and private asset endpoints.
