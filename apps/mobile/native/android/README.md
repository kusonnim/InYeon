# Android native code

The [Android runner](../../android/app/src/main/kotlin/com/itda/itda_mobile/)
owns share receipt, authenticated uploads, and notification presentation.
`AndroidNotifications` joins the acknowledged outbox to `NoticeLifecycle`
and schedules versioned mutations and content refreshes through WorkManager.
`AndroidNoticeSurface` owns the channel, platform identity, and pending intents.
See the [mobile guide](../../README.md#android-notifications) for behavior,
mock setup, and verification.
