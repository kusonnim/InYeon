# ITDA mobile — Developer A

ITDA opens to a private library of saved items. On Android, the library combines
originals on this device with the signed-in account's server catalog. The native
outbox delivers assigned shares, and Android notifications present acknowledged
items. A separate sample library uses synthetic fixtures.
Read the root [AGENTS.md](../../AGENTS.md), [product contract](../../docs/PRODUCT.md),
and [OpenAPI](../../contracts/openapi.yaml) before changing behavior.

## Run and verify

Install Flutter stable and the Android SDK. Use the JDK bundled with Android
Studio or a compatible JDK. Repository CI pins Flutter 3.47.9. The Android runner
and app dependency lockfile are checked in. Run from `apps/mobile` with an
Android emulator or device.

~~~sh
flutter pub get --enforce-lockfile
flutter gen-l10n
dart run tool/sync_fixtures.dart --check
flutter analyze
flutter test
flutter build apk --debug
flutter run -d <android-device-id>
~~~

After the APK build initializes the Gradle wrapper, run the native tests on a
disposable Android test device from `apps/mobile/android`.

~~~sh
./gradlew :app:connectedDebugAndroidTest :app:lintDebug
~~~

Use `gradlew.bat` on Windows. The suite exercises receipt persistence, stable keys,
file copying and hashing, interrupted receipt writes, the HTTP upload protocol,
and Android notification state, actions, and authenticated retries. Use a
disposable installation for instrumentation.

## Library and details

The library reads an authenticated page on launch, resume, and refresh. A new
upload acknowledgment also refreshes the list. **Load more** uses the server
cursor. A receipt and server item with the same acknowledged ID share one card.
Dismissed and archived items remain accessible. **Sample library** is available
from **Account** and from an empty device-only library.

Cards show the saved title or a source-derived label, the source type, and any
available summary and recommendation preview. A device-only item shows its
upload state. Details separate the original source, AI summary and coverage,
information, action and resource recommendations, and personal notes. A pending
item can open its local original while offline. File details show the stored
name or a private attachment label. File preview and download are future work.

Loaded catalog pages stay in memory during a connection error.
Account changes clear it, and offline launches can show durable device receipts.
Server-only items need a successful load in the current app session. The mobile
client uses the existing owner-scoped list and detail APIs. Incremental sync
remains integration work.

**Edit** updates only the fields the user changed. A version conflict keeps the
draft and offers to load the latest version. Untouched fields adopt the latest
server values. The editor displays the competing saved value for each changed
field before the user saves again. Existing recommendations are available for
review in the editor.

The app follows Android's light and dark setting. Flutter interface strings
are in `lib/l10n/app_en.arb`; generated Dart files stay local. The Android
notification action keeps its existing label **수정하기**.
[Flutter localization guide](https://docs.flutter.dev/ui/internationalization)

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

Open ITDA to see the new item in **Library**. The list refreshes on app resume
and on native receipt or upload changes.

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

Open **Account** and use **Sign in** with a pre-existing Supabase email/password
account. The native client stores the access and refresh tokens in an Android Keystore
encrypted vault. It refreshes the session when the token is about to expire
or when an API request returns 401. Account sign-out clears the device session.
Tokens stay in native code and the app only exposes account labels to Flutter.
[Supabase session behavior](https://supabase.com/docs/guides/auth/sessions)

New shares are assigned to the active user and API destination when saved.
For A1 shares and shares received while signed out, open the item and select
**Choose account**. Confirm the displayed account for each item. Assigned
receipts keep that user and destination across account changes. Another
account sees a redacted card.

| State | Behavior |
| --- | --- |
| Waiting to sync | An assigned item is queued for a connected network |
| Syncing | A worker is submitting or resuming the item |
| Waiting to retry | A temporary network, server, or local storage error delayed the attempt |
| Sign-in required / Choose an account | The item needs a session for its original account or explicit assignment |
| Synced | The matching server content ID was durably saved after a valid 201 acknowledgment, or the item was read from the authenticated catalog |
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

## Android notifications

Sign in and select **Enable notifications** in **Account** to grant Android 13+ permission.
The same control opens notification settings when the system prompt is unavailable
or the **Saved content** channel is blocked. Permission denial leaves the library
and upload outbox accessible.
[Android notification permission](https://developer.android.com/develop/ui/views/notifications/notification-permission)

After upload acknowledgment is persisted, a worker reads the current content from
the API and posts one card for its active notification generation. New local
shares need a server content ID before they can post. Analysis updates change an
existing card in place and without another alert. The controller reads state on
registration, app launch or resume, and **Refresh library**. In-app details
also offer a refresh. Notification text reports the current analysis status.
Source text and private links stay out of the notification.

The body opens the registered item's details. The sole quick action
**수정하기** opens its title and notes editor. Edits require the current
content version. On a conflict the user can refresh while retaining their draft.
The sample library remains separate. Mock notifications and registered
details are labeled as mock, and mock edits are stored in the test server's
memory.

Swiping the card commits a local dismissal and a stable event key before
scheduling the server request. The item and its workflow stay in the library.
The notification store uses atomically replaced records under
`noBackupFilesDir/notification-inbox-v1/`, keyed by the API realm, user and
acknowledged content ID. Records hold server visibility, generation and revision,
a local suppression marker, an issuance marker, and a pending mutation when
needed. WorkManager uses the A2 session, a connected network, unique per-content
work and exponential backoff. The original account resumes its queued events
after signing back in.

Open an eligible item in **Library** and select
**Restore notification** after dismissal has synchronized. A queued restore
leaves the card hidden until the server confirms the current state. A version
conflict refreshes state. A dismissal may retry at the new revision of the same
generation with a new key. A conflicting restoration requires a fresh tap.
Older-generation dismissals cannot suppress the restored card. Eligibility
comes from an acknowledged receipt on this device. Catalog-only items can show
their server visibility in details.

Signing out or switching accounts hides the previous account's Android cards
without sending dismissal events. Android cards already issued for a generation
stay absent after a programmatic cancel or a restart that clears the shade.
An interrupted first post can also leave a generation issued with no card.
This presentation policy prioritizes durable suppression. See the
[presentation ADR](../../docs/decisions/0005-android-notification-presentation.md).

## Configure an upload destination

The sample library uses the `ContentApi` fixture adapter and the synthetic
catalog copied from `contracts/examples/catalog.json`. The signed-in library uses
the native authenticated catalog bridge with the same content models.

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
python apps/mobile/tool/mock_upload_server.py --seed-catalog
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
host alias. **Mock mode** labels the library and account. **Mock content**
labels registered details and edits. The optional seed adds synthetic
catalog-only items to account A. Account B starts with an empty catalog.
For the lost-acknowledgment check, add the options
`--expire-first-capability --hold-source-text A2_PROCESS_KILL`, send the synthetic text `A2_PROCESS_KILL`, and
terminate the app process when the mock reports that it committed the request.
The retry should replay the receipt using the original key.

For notifications, share synthetic text after signing in. Grant permission
and confirm one card with the mock label. Use a synthetic user's access token
from the loopback password endpoint and the registered mock content ID to
advance the analysis status.

```sh
curl -fsS -X POST "http://127.0.0.1:8782/mock/analysis/${CONTENT_ID}" \
  -H "Authorization: Bearer ${MOCK_ACCESS_TOKEN}" \
  -H "Content-Type: application/json" --data '{"status":"completed"}'
```

The mock-only route accepts the contract's five analysis statuses. Completed
and partial results reuse the synthetic catalog. Open the app or select
**Refresh library** and confirm the card's text changes while its ID stays the
same. Turn on airplane mode and swipe the card. Restart the app, advance the
mock analysis again, and reconnect. The card stays hidden. After the dismissal
is synchronized, restore from details and verify a single new generation.

The [integration contract](../../docs/INTEGRATION.md) describes the dependencies
on real authentication, content and notification persistence, private assets,
and the future FCM delivery contract. See [verification results](../../docs/STATUS.md#phase-a4-android-checks).
