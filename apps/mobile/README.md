# ITDA mobile — Developer A

Flutter/Dart Android-first Phase 0 foundation. Read root AGENTS.md, docs/PRODUCT.md, docs/OWNERSHIP.md and contracts/openapi.yaml before changing behavior.

## Install and run

Install the stable Flutter SDK and Android SDK; use Java 17 or the Java version required by your installed Flutter Android tooling. Flutter/Dart were absent on the Phase 0 authoring host, so Flutter checks and Android execution require CI or a developer machine.

From apps/mobile, first generate the Android runner using Flutter's own templates:

```sh
flutter create --platforms=android --org com.itda --project-name itda_mobile .
dart run tool/sync_fixtures.dart
flutter pub get
flutter analyze
flutter test
flutter devices
flutter run -d <android-device-id> --dart-define=ITDA_DATA_MODE=fixture
```

Do not add --overwrite. Existing lib/, test/ and pubspec.yaml are the application source and must remain intact. Review the generated Android files and commit the runner and pubspec.lock when Flutter tooling is available. No iOS target is required. The checked-in native/android interfaces remain separate from generated Android files until durable integrations are implemented.

The default app reads synthetic assets/fixtures/catalog.json, bundled from the canonical contracts/examples/catalog.json. To verify the copy after contract edits:

```sh
dart run tool/sync_fixtures.dart --check
```

The main route shows a fixture library; /contents/{id} shows source, AI interpretation, user notes, recommendations and separate workflow/notification state. Editing is visibly planned. Sign-in, sharing, persistence, uploads, native notifications and synchronization are not implemented.

## API boundary

ContentApi is the replaceable interface. FixtureContentApi stores simulated edits in memory for tests only. HttpContentApi includes bearer authentication and explicit version preconditions, but is not wired to the app until Supabase authentication is available. Tokens must be obtained from the current user session; never embed privileged service credentials. ITDA_DATA_MODE values other than fixture fail closed. .env.example documents configuration; Flutter uses --dart-define rather than reading dotenv automatically.

Kotlin and Dart native placeholders describe the required durable share handoff and independent notification state. They are not registered as Android share targets. Do not enable receipt acknowledgement before persisting the source and stable retry key.

Next work: generated Android runner, durable outbox and private attachment copies, Android share receiver, auth/upload integration, notification state machine with tombstones, and device lifecycle tests. Shared schemas belong to the contract; coordinate changes with B and C.

Official setup references: [Flutter installation](https://docs.flutter.dev/install), [Android setup](https://docs.flutter.dev/platform-integration/android/setup), and [creating an app](https://docs.flutter.dev/reference/create-new-app).
