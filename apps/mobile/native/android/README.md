# Android integration boundary

The Kotlin interfaces here are unregistered placeholders, not functioning native integrations. They intentionally live outside the Android runner so bootstrap cannot overwrite them. The Phase 0 Flutter app cannot receive shares or show notifications.

Developer A must implement durable local payload/outbox storage and attachment copying before adding SEND / SEND_MULTIPLE intent filters. Android grant URIs can expire; copy bytes into private storage before acknowledging receipt. Generate the server ingestion idempotency key once per local outbox record and reuse it across upload/retry. A new intentional share gets a new key.

After the local commit, close the share UI promptly without awaiting API or AI. Upload assets privately, confirm upload completion, then submit content. Keep source, analysis and edits separate.

Use a stable platform notification ID per content. Track active/dismissed, generation, revision and local dismissal tombstones durably. Only explicit restoration creates a new generation. Ignore delayed dismissals for older generations. Suppress automatic resurrection after process death, analysis, push, sync and permission changes. Body tap opens /contents/{id}; the only quick action is Edit (수정하기). No complete/delete quick actions.

Planned native permission handling, background upload, OS-specific lifecycle testing, FCM registration and notification reconciliation require Android emulator/device tests. Unit fixtures do not establish these guarantees.
