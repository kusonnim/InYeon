# ITDA mobile — Developer A

The Flutter app displays the synthetic catalog and shares saved on this Android
device. Read the root [AGENTS.md](../../AGENTS.md), [product contract](../../docs/PRODUCT.md),
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
file copying and hashing, unreadable input, interrupted writes, storage failure,
and a receiver recreation before the success result.

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

Open ITDA to see **Saved on this device** and **Pending upload** for each receipt.
The section refreshes on app resume. File rows show the display filename. The
separate **Sample library** keeps the synthetic fixture list and details.

## Inbox and outbox

The app stores each share under `noBackupFilesDir/share-inbox-v1/<local_id>/`.
Each directory holds `receipt.json` and, for a file share, the copied source file
referenced by the receipt. The record stores the local UUID, `client_event_id` UUID,
`input_type`, original source, available metadata, `received_at_ms`, `upload_state`
(`pending_upload`), and `last_error` (initially null). Attachment records include the
relative file reference, filename, detected MIME type, actual byte count and
SHA-256. Device backups are disabled for the app.

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

## Share-sheet check

Launch ITDA on a disposable emulator or device. Share text and a page URL from a
browser, then share a PNG and a PDF from Files. Confirm ITDA closes and the
sending app returns after each receipt. Repeat with Wi-Fi and mobile data off.
Force-stop and reopen ITDA and confirm that all accepted shares still appear as
pending. Delete the sender's test files and verify the private copies still exist.
Use the native suite above for controlled recreation, storage failure and
acknowledgment checks.

## API boundary and Phase A2

`ContentApi` is the replaceable catalog interface. The default `ITDA_DATA_MODE` is
`fixture` and uses the synthetic catalog copied from `contracts/examples/catalog.json`.
`HttpContentApi` requires authenticated session wiring. Use user session tokens
and keep privileged service credentials server-side.

Phase A2 will send the durable outbox through the authenticated API. Map
`client_event_id` to the content-create `Idempotency-Key` header. For attachments,
reserve a private upload using the recorded filename, media type, size and hash,
upload the copied bytes, confirm completion and attach the returned asset ID.
Persist upload progress and errors for retries. Keep the original until the server
receipt and local reconciliation are durable. The [integration contract](../../docs/INTEGRATION.md)
describes the shared boundaries. Notification lifecycle work follows this step.
