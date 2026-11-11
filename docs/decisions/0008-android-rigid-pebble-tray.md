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

## Phase A7.2 amendment

The [mobile design draft](../DESIGN.md) defines a nearly circular rounded
triangle. Each variant has a six-point convex hull and an outward rounding
radius. Box2D applies that radius to the fixture. The painter draws the same
offset edges and circular arcs. Diameter uses the tray's available area and
capacity to accommodate the taller shapes. The identity hash and color
assignment carry forward from A7.1.

The versioned archive action accepts either pending or completed as its
starting workflow value. The existing fixture backend and Android loopback
mock already accept these PATCHes. Each drag or button action sends
`workflow_status: archived` with the current version. An explicit restore
sends `workflow_status: pending`. A successful response with the expected
account, item, destination, and advanced version authorizes the UI update.

## Phase A7.3 amendment

Each pebble has three rounded corners and three gently convex circular sides.
The five deterministic variants share a corner radius of 0.105 and a side bow
of 0.028 in normalized coordinates. The painted side arcs meet the corner arcs
tangentially. Box2D rounds a six-point convex hull with the same corner radius.
The six samples are the three corner centers and the three midpoints of the
side arcs before the outline offset.
