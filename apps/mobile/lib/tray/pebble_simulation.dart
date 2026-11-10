import 'dart:math' as math;
import 'dart:ui';

import 'package:forge2d/forge2d.dart';

/// The same convex silhouettes drive the artwork and the collision fixtures.
final class PebbleDesign {
  const PebbleDesign(this.variant, this.color);

  factory PebbleDesign.forId(String id) {
    var hash = 0x811c9dc5;
    for (final unit in id.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return PebbleDesign(hash % _outlines.length, (hash >> 8) % 6);
  }

  final int variant;
  final int color;

  List<Offset> get outline => _outlines[variant];

  static const _outlines = [
    [
      Offset(-.50, -.08),
      Offset(-.34, -.30),
      Offset(.07, -.34),
      Offset(.40, -.23),
      Offset(.49, .04),
      Offset(.25, .29),
      Offset(-.16, .33),
      Offset(-.43, .21),
    ],
    [
      Offset(-.48, -.18),
      Offset(-.21, -.33),
      Offset(.15, -.31),
      Offset(.46, -.08),
      Offset(.44, .18),
      Offset(.16, .33),
      Offset(-.22, .28),
      Offset(-.49, .09),
    ],
    [
      Offset(-.50, .02),
      Offset(-.36, -.25),
      Offset(-.03, -.34),
      Offset(.28, -.27),
      Offset(.48, -.08),
      Offset(.39, .24),
      Offset(.04, .34),
      Offset(-.31, .27),
    ],
    [
      Offset(-.46, -.14),
      Offset(-.14, -.32),
      Offset(.26, -.32),
      Offset(.49, -.13),
      Offset(.47, .11),
      Offset(.20, .28),
      Offset(-.26, .34),
      Offset(-.49, .17),
    ],
    [
      Offset(-.50, -.12),
      Offset(-.32, -.28),
      Offset(.05, -.35),
      Offset(.36, -.18),
      Offset(.48, .11),
      Offset(.23, .30),
      Offset(-.18, .33),
      Offset(-.42, .18),
    ],
  ];
}

final class TrayGeometry {
  const TrayGeometry(this.size);

  final Size size;

  Rect get interior =>
      Rect.fromLTRB(8, size.height * .22, size.width - 8, size.height - 8);

  bool get fits => size.width >= 170 && size.height >= 112;

  double get pebbleWidth =>
      math.min(138, math.min(interior.width * .44, interior.height * .49));

  int get capacity {
    if (!fits) return 0;
    if (interior.height < 155) return 4;
    return size.width < 320 || interior.height < 265 ? 6 : 10;
  }
}

typedef PebblePose = ({
  String id,
  Offset center,
  double angle,
  PebbleDesign design,
});

/// Box2D coordinates use meters with positive Y down to match the canvas.
final class PebbleSimulation {
  PebbleSimulation(this.geometry) : assert(geometry.fits) {
    final tray = geometry.interior;
    const wall = 16.0;
    final top = -geometry.pebbleWidth * 3;
    final wallHeight = tray.bottom + wall - top;
    _box(Rect.fromLTWH(tray.left - wall, top, wall, wallHeight));
    _box(Rect.fromLTWH(tray.right, top, wall, wallHeight));
    _box(Rect.fromLTWH(tray.left, tray.bottom, tray.width, wall));
  }

  static const frameSeconds = 1 / 60;
  static const _pixelsPerMeter = 64.0;
  static const _releaseInterval = 6;

  final TrayGeometry geometry;
  final _world = World(gravity: Vector2(0, 22));
  late final _walls = _world.createBody();
  final _bodies = <String, ({Body body, PebbleDesign design})>{};
  final _queued = <String, int>{};
  var _frame = 0;
  var _spawnIndex = 0;
  MouseJoint? _joint;
  String? draggedId;

  bool get moving =>
      _queued.isNotEmpty || _bodies.values.any((stone) => stone.body.isAwake);

  Iterable<PebblePose> get poses => _bodies.entries.map((entry) {
    final stone = entry.value;
    final position = stone.body.position;
    return (
      id: entry.key,
      center: Offset(position.x, position.y) * _pixelsPerMeter,
      angle: stone.body.angle,
      design: stone.design,
    );
  });

  void sync(Iterable<String> ids) {
    final selected = ids.take(geometry.capacity).toSet();
    _queued.removeWhere((id, _) => !selected.contains(id));
    for (final id
        in _bodies.keys.where((id) => !selected.contains(id)).toList()) {
      if (id == draggedId) release();
      _bodies.remove(id)!.body.destroy();
    }
    var nextRelease = _queued.isEmpty
        ? _frame + 4
        : _queued.values.last + _releaseInterval;
    for (final id in selected) {
      if (_bodies.containsKey(id) || _queued.containsKey(id)) continue;
      _queued[id] = nextRelease;
      nextRelease += _releaseInterval;
    }
  }

  void step() {
    ++_frame;
    while (_queued.isNotEmpty && _queued.values.first <= _frame) {
      _spawn(_queued.keys.first);
    }
    _world.step(frameSeconds);
  }

  /// Prepare a resting arrangement for reduced motion or a resized viewport.
  void settle() {
    for (var frame = 0; frame < 540 && moving; ++frame) {
      step();
    }
    for (final stone in _bodies.values) {
      if (stone.body.isAwake) stone.body.isAwake = false;
    }
  }

  bool pickUp(String id, Offset pointer) {
    final body = _bodies[id]?.body;
    if (body == null || draggedId != null) return false;
    draggedId = id;
    body.isAwake = true;
    _joint = _world.createMouseJoint(
      MouseJointDef(
        bodyA: _walls,
        bodyB: body,
        target: _point(pointer),
        maxForce: body.mass * 105,
        hertz: 6,
        dampingRatio: .9,
        collideConnected: true,
      ),
    );
    return true;
  }

  void drag(Offset pointer) {
    final tray = geometry.interior;
    _joint?.target = _point(
      Offset(
        pointer.dx.clamp(tray.left, tray.right),
        pointer.dy.clamp(tray.top, tray.bottom),
      ),
    );
  }

  void release() {
    _joint?.destroy();
    _joint = null;
    draggedId = null;
  }

  void dispose() => _world.destroy();

  void _box(Rect rect) => _walls.createShape(
    Polygon.offsetBox(
      rect.width / (2 * _pixelsPerMeter),
      rect.height / (2 * _pixelsPerMeter),
      center: _point(rect.center),
    ),
    ShapeDef(material: SurfaceMaterial(friction: .78, restitution: .19)),
  );

  void _spawn(String id) {
    _queued.remove(id);
    final design = PebbleDesign.forId(id);
    final tray = geometry.interior;
    final width = geometry.pebbleWidth;
    const lanes = [.39, .67, .25, .55, .74, .47, .32, .60, .23, .71];
    final lane = lanes[_spawnIndex++ % lanes.length];
    final x = (tray.left + tray.width * lane).clamp(
      tray.left + width * .55,
      tray.right - width * .55,
    );
    final body = _world.createBody(
      BodyDef(
        type: BodyType.dynamic,
        position: _point(Offset(x, -width * .6)),
        rotation: Rot.fromAngle((design.variant - 2) * .22),
        linearVelocity: Vector2((lane - .5) * 1.8, 0),
        angularVelocity: (design.variant - 2) * .5,
        linearDamping: .55,
        angularDamping: 1.15,
        isBullet: true,
      ),
    );
    body.createShape(
      Polygon([for (final point in design.outline) _point(point * width)]),
      ShapeDef(
        material: SurfaceMaterial(
          friction: .74,
          restitution: .22,
          rollingResistance: .05,
        ),
      ),
    );
    _bodies[id] = (body: body, design: design);
  }

  Vector2 _point(Offset point) =>
      Vector2(point.dx / _pixelsPerMeter, point.dy / _pixelsPerMeter);
}
