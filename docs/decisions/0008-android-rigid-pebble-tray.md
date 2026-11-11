# 0008 Android rigid pebble tray

Status accepted for Phase A7.1.

The tray is a Flutter presentation of the existing account and realm scoped
library projection. Receipt identity takes priority when a local original is
paired with its server content. The tray sorts by the receipt time when one is
available and otherwise by server creation time. The capped scene and the two
lists read the same records. The tray keeps its state under detail routes and
resets when the active scope changes. Positions and drag gestures live only in
the current app session.

Forge2D 0.15 provides the maintained native Box2D engine. Using it directly
keeps the Flutter navigation and semantics tree in place and avoids a separate
game framework. The older pure-Dart Forge2D line would avoid C compilation.
The native line adds a build hook and requires the Android NDK and a host C
toolchain for Flutter tests. [Forge2D package](https://pub.dev/packages/forge2d/versions/0.15.3)

Each stone has a convex fixture and a rounded rendering of the same outline.
The scene uses three static wall fixtures, a 60 Hz step with bounded catch-up,
staggered release above the viewport, and a force-limited mouse joint for
dragging. Box2D sleeping stops Flutter's simulation ticker. Resize and reduced
motion prepare the same arrangement before painting. Upright labels truncate
visually. The lists follow the app's text scale and expose full labels to
assistive technology.

Workflow uses the established content PATCH with the last observed version.
Completion is explicit. An archive drop targets the destination with the pointer
while the pebble respects the tray floor. The pebble leaves only after a verified
archive response. Returning from the archive sets workflow to pending. A stale
version requires review and a fresh action. Notification and analysis states
stay separate from the projection.
