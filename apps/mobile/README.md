# ITDA mobile — Developer A

ITDA opens to a private library of saved items. On Android, the library combines
originals on this device with a durable copy of the signed-in account's server
catalog. The native outbox delivers assigned shares, and Android notifications
present acknowledged items. A separate sample library uses synthetic fixtures.
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
Android notification state and actions, authenticated retries, and SQLite
synchronization recovery. Use a disposable installation for instrumentation.

## Library and details

The library reads the active account's local snapshot first. **Load more** reads
more items from SQLite. A receipt and server item with the same acknowledged ID
share one card. A server deletion removes the synchronized card while retaining
the device original. Dismissed and archived items remain accessible. **Sample
library** is available from **Account** and from an empty device-only library.

Cards show the source type, display title, up to two lines of labeled AI
summary, and compact status badges. Recommendations are in details. The library
groups loaded saves with the exact same source URL, including its query and
fragment. Expand a group to see each save's own title, timestamp, state, and
details. The group has no effect on ingestion or synchronization.

A saved title takes priority over an Android share subject or a title line
shared alongside a URL. When these are absent, a localized label names the
available host. The client preserves the original URL and makes no webpage
requests to obtain a title. Android share subjects are local receipt metadata.
Preserving their provenance across devices requires a contract review with
Developer B.

Details separate the original source, AI summary and coverage, recommendations,
and personal notes. Tap a web URL or **Open original** to leave ITDA through
Android's app-link and browser resolution. Source links work for local and
synchronized items while analysis is pending. Recommendation references offer
**Open resource** and **Copy link**. The original-source and reference controls
also work in the editor. Use Android Back to return to the same ITDA screen.

External launch requires an absolute HTTP or HTTPS URL. The app rejects
credentials and known private storage links and passes only the web URL to
Android. Link opening and copying leave the saved URL unchanged. If Android
cannot open the URL, ITDA reports the failure in the selected app language.

Locally saved JPEG, PNG and WebP files preview inline in
details and in the registered editor. Tap an image for a larger view, then
pinch to zoom and drag to pan. Pending and synchronized originals are available
offline when the matching device copy is present. Android checks the receipt ID,
owner and API realm, expected private path, file type, byte count, and checksum
before returning an in-process path. Both views preserve aspect ratio and cap
decode dimensions. Images over 64 megapixels stay saved and show an unavailable
preview.

For a server-only image the screen explains that private download is
unavailable. The authenticated `GET /v1/assets/{id}/download-url` contract
requires a short-lived owner-scoped capability, and the checked-in backend
returns 501. PDFs retain their original-file details behavior.

After an initial sync, server-only items are available across offline restarts
with the same installed session. **Saved copies** identifies a catalog awaiting
confirmation or recovering from an error. **Syncing library** tracks active
work. **Refresh library** requests background sync. A cached detail can show
the source and saved fields offline. Editing requires a current authenticated
detail response. Sign-out clears the visible account projection. A different
account or API destination has a separate snapshot.

Tap the title or the personal notes card in editable details to focus that field
in the existing editor. The notes card works when the note is empty. App-bar
**Edit** and the notification action also open this editor. It pre-fills the
saved title and personal notes and shows the original in a read-only section.
An item without a saved title shows a source-derived hint.
The hint stays separate from the draft and only changed fields are sent in PATCH.
A version conflict keeps the draft and offers to load the latest version.
Untouched fields adopt the latest server values. The editor displays competing
saved values before the user saves again. Existing recommendations are
available for review in the editor.

The app follows Android's light and dark setting. Korean is the default app
language regardless of the system locale. Choose **한국어** or **English** under
**App language** in **Account**. Changes apply immediately and persist across
restarts and account switches. Android uses the same installation preference
when Flutter is closed. Flutter ARB files and Android string resources cover
interface text, dates, accessibility labels, share feedback, and notifications.
Saved originals, edits, and analysis stay in their original language.
Android app bundles keep both sets of string resources so switching works offline.
[Flutter localization guide](https://docs.flutter.dev/ui/internationalization)

## Android library synchronization

The Android worker consumes every page from `GET /v1/sync` in server sequence
order. It reuses each opaque cursor as issued and compares decimal sequences
without floating-point conversion. It resolves content and related recommendation
or notification events with an authenticated content read, and preferences with
`GET /v1/preferences`. Each page's upserts, tombstones and checkpoint commit
together. If a request or the process stops midway, the next worker starts
from the last committed page.

On first sign-in or HTTP 400 `invalid_cursor`, the worker establishes a feed
boundary, stages the full paginated catalog and preferences, then applies
changes after that boundary. This catches inserts above an already traversed
list page and changes to previously staged records. Publication replaces the
active snapshot and cursor in one transaction. The old snapshot stays readable
during a rebuild. An interrupted or expired rebuild restarts from a fresh
boundary. Incremental work resumes from its durable checkpoint.

SQLite files live under `noBackupFilesDir/library-cache-v1/` and are partitioned
by API realm and Supabase user ID. The Android app sandbox protects the cache.
Schema version 1 is created on first use, with no backfill from the A4 in-memory
catalog. The A1/A2 original and upload stores and A3 suppression records remain
separate. Android's SQLite corruption recovery can discard an affected derived
snapshot, which the next sync rebuilds. A future schema upgrade needs an
explicit cache migration or versioned rebuild.

Successful sign-in, launch/resume, manual refresh, network reconnection while
the app process is alive, and a durable upload acknowledgment request a sync.
WorkManager persists account-scoped jobs and waits for a connected network,
including when Flutter is closed. Triggers coalesce behind active work and
temporary failures back off exponentially from 30 seconds to WorkManager's
five-hour maximum. Android can defer work. When no worker is pending and the
process is stopped, a later launch requests the next sync.
The worker checks the active account before applying pages and publishing a
rebuild. Flutter can read only the current account's snapshot. Successful token
refresh retains the same partition and rejected sessions require sign-in.

Changed items acknowledged on this device can trigger the existing A3
authoritative notification refresh. Cached rows never determine notification
presentation, and synchronization preserves local suppression and open edit
drafts. FCM hints require the shared device registration and dispatch design.
[Android sync ADR](../../docs/decisions/0006-android-library-sync-checkpoints.md)

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
| Synced | The matching server content ID was durably saved after a valid 201 acknowledgment, or the item came from an authenticated server snapshot. **Saved copies** indicates the library is awaiting confirmation |
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
also offer a refresh. A notification shows the identified sender or source host
when available, a saved title or share subject, and a localized processing,
completed, partial, or failed status. Localized fallbacks cover absent metadata.
Raw source text, analysis summaries, and private URLs stay out of the card.
Title and language changes update active cards in place. The existing generation
ledger still suppresses dismissed or missing cards.

The body opens the registered item's details. The sole quick action
**Edit / 수정하기** opens its title and notes editor. Edits require the current
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

Android reads upload destinations at build time.

| `ITDA_UPLOAD_MODE` | Build settings | Destination |
| --- | --- | --- |
| `disabled` (default) | None | Shares stay on the device |
| `mock` | `ITDA_API_BASE_URL`, `ITDA_SUPABASE_URL`, `ITDA_SUPABASE_PUBLISHABLE_KEY` | Debug-only loopback contract mock |
| `staging` | `ITDA_STAGING_API_BASE_URL`, `ITDA_STAGING_SUPABASE_URL`, `ITDA_STAGING_SUPABASE_PUBLISHABLE_KEY` | Debug-only **ITDA Staging** installation with its own app storage and HTTPS API |
| `live` | `ITDA_API_BASE_URL`, `ITDA_SUPABASE_URL`, `ITDA_SUPABASE_PUBLISHABLE_KEY` | Configured HTTPS production API |

Upload-enabled builds require absolute base URLs and a Supabase `sb_publishable_`
key. Base URLs cannot contain credentials, a query, or a fragment. Use a separate
build shell for staging and confirm its API host in **Account** before signing
in. Its package is `com.itda.itda_mobile.staging`. Its receipts, session and caches
belong to that installation and the existing account and API-realm binding.
The default build packages no endpoint values. See the
[staging runbook](STAGING.md) for preflight, credentials handling, and verification.
[Supabase key types](https://supabase.com/docs/guides/getting-started/api-keys)

## Loopback contract mock

Run the mock from the repository root with Python and the `PyYAML` and
`jsonschema` packages installed. It validates the exercised API requests and
responses against OpenAPI. It uses synthetic users and in-memory state.

```sh
python apps/mobile/tool/mock_upload_server.py --seed-catalog --sync-page-size 2 --replay-sync-prefix
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

For synchronization, sign in as A and wait for the seeded items. With airplane
mode enabled, stop and reopen the app and confirm that **Saved copies** includes
server-only items. Use authenticated mock requests to edit or add an item and
reconnect. The library should catch up without a manual refresh. Sign in as B
to verify account isolation.

The authenticated loopback-only `POST /mock/sync` accepts a JSON `action`.
`expire_cursor` invalidates issued sync cursors for the caller.
`hold_next_catalog` delays the next captured list response, giving a test time
to insert a newer item during bootstrap. `hold_next_content` takes a
`content_id` and delays its next captured detail response, allowing process
termination before page commit. `delete_content` takes a `content_id` and
emits a content tombstone. Keep the mock running during these scenarios so
its synthetic feed remains available.

The [integration contract](../../docs/INTEGRATION.md) describes the dependencies
on real authentication, durable content and sync persistence, private assets,
and the future FCM delivery contract. See the
[mobile verification results](../../docs/STATUS.md#phase-a61-android-checks).
