import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge2d/forge2d.dart';
import 'package:itda_mobile/tray/pebble_design.dart';
import 'package:itda_mobile/tray/pebble_simulation.dart';

const _regular = TrayGeometry(Size(360, 460));

void main() {
  test('saved identities yield stable and varied silhouettes and colors', () {
    final ids = List.generate(32, (index) => 'local:receipt-$index');
    final designs = ids.map(PebbleDesign.forId).toList();
    expect(designs.map((design) => design.variant).toSet(), hasLength(5));
    expect(designs.map((design) => design.color).toSet(), hasLength(6));
    for (final (index, id) in ids.indexed) {
      final same = PebbleDesign.forId(id);
      expect(same.vertices, designs[index].vertices);
      expect(same.color, designs[index].color);
    }
  });

  test('each matte silhouette follows the rounded Box2D boundary', () {
    final world = World(gravity: Vector2.zero());
    addTearDown(world.destroy);
    final variants = <int>{};
    for (var index = 0; index < 32; index++) {
      final design = PebbleDesign.forId('local:receipt-$index');
      if (!variants.add(design.variant)) continue;
      final body = world.createBody();
      final fixture = body.createShape(
        Polygon([
          for (final p in design.vertices) Vector2(p.dx, p.dy),
        ], radius: PebbleDesign.radius),
      );
      final path = design.silhouette;
      for (var angle = 0; angle < 360; angle += 3) {
        final direction = angle * math.pi / 180;
        expect(path.contains(Offset.fromDirection(direction, .42)), isTrue);
        expect(path.contains(Offset.fromDirection(direction, .51)), isFalse);
        final visibleRadius = _edgeRadius(direction, path.contains);
        final fixtureRadius = _edgeRadius(
          direction, (p) => fixture.testPoint(Vector2(p.dx, p.dy)),
        );
        expect(
          visibleRadius,
          closeTo(fixtureRadius, .0015),
          reason: 'Variant ${design.variant} at $angle°',
        );
      }
      body.destroy();
    }
    expect(variants, hasLength(5));
  });

  test('releases a staggered cascade above the tray and falls to sleep', () {
    final scene = PebbleSimulation(_regular);
    addTearDown(scene.dispose);
    scene.sync(['a', 'b', 'c', 'd', 'e']);
    expect(scene.poses, isEmpty);
    _steps(scene, 4);
    final first = scene.poses.single;
    expect(first.id, 'a');
    expect(first.center.dy, lessThan(0));
    _steps(scene, 12);
    expect(scene.poses, hasLength(3));
    expect(scene.poses.first.center.dy, greaterThan(first.center.dy));
    final steps = _runUntilSleep(scene);
    expect(steps, lessThan(540));
    expect(scene.moving, isFalse);
    _expectContained(scene);
    _expectSeparated(scene);
  });

  test('snapshot changes retain bodies and release only new identities', () {
    final scene = PebbleSimulation(_regular);
    addTearDown(scene.dispose);
    scene.sync(['one', 'two']);
    scene.settle();
    final settled = scene.poses.toList();
    scene.sync(['two', 'one']);
    expect(scene.poses.toList(), settled);
    expect(scene.moving, isFalse);
    scene.sync(['new', 'two', 'one']);
    expect(scene.poses.toList(), settled);
    _steps(scene, 4);
    expect(scene.poses.last.id, 'new');
    expect(scene.poses.last.center.dy, lessThan(0));
    expect(scene.poses.take(2).toList(), settled);
    _runUntilSleep(scene);
    expect(scene.poses, hasLength(3));
  });

  test(
    'a mouse joint moves the stone while respecting the floor and walls',
    () {
      final scene = PebbleSimulation(_regular);
      addTearDown(scene.dispose);
      scene.sync(['one', 'two', 'three']);
      scene.settle();
      final initial = scene.poses.first;
      expect(scene.pickUp(initial.id, initial.center), isTrue);
      expect(scene.pickUp('two', initial.center), isFalse);
      final tray = scene.geometry.interior;
      final oppositeSide = initial.center.dx < tray.center.dx
          ? tray.right + 150
          : tray.left - 150;
      scene.drag(Offset(oppositeSide, tray.top - 150));
      _steps(scene, 90);
      final held = scene.poses.first;
      expect((held.center - initial.center).distance, greaterThan(15));
      expect(held.design, same(initial.design));
      _expectContained(scene, tolerance: 4);
      scene.release();
      expect(scene.draggedId, isNull);
      _runUntilSleep(scene);
      _expectSeparated(scene);
    },
  );

  test('bounds work with hundreds of entries and differently sized trays', () {
    final ids = List.generate(500, (index) => 'local:$index');
    for (final geometry in [
      _regular,
      const TrayGeometry(Size(244, 500)),
      const TrayGeometry(Size(600, 185)),
    ]) {
      final scene = PebbleSimulation(geometry);
      try {
        scene.sync(ids);
        final timer = Stopwatch()..start();
        final steps = _runUntilSleep(scene);
        timer.stop();
        expect(scene.poses.length, geometry.capacity);
        expect(steps, lessThan(540));
        _expectContained(scene);
        _expectSeparated(scene);
        debugPrint(
          '${geometry.size.width}×${geometry.size.height} '
          '${scene.poses.length} bodies, $steps steps, '
          '${(timer.elapsedMicroseconds / steps).toStringAsFixed(1)} µs/step',
        );
      } finally {
        scene.dispose();
      }
    }
    expect(const TrayGeometry(Size(120, 110)).capacity, 0);
  });
}

double _edgeRadius(double direction, bool Function(Offset) contains) {
  var inside = .42;
  var outside = .52;
  while (outside - inside > .00002) {
    final radius = (inside + outside) / 2;
    if (contains(Offset.fromDirection(direction, radius))) {
      inside = radius;
    } else {
      outside = radius;
    }
  }
  return (inside + outside) / 2;
}

void _steps(PebbleSimulation scene, int count) {
  for (var step = 0; step < count; ++step) {
    scene.step();
  }
}

int _runUntilSleep(PebbleSimulation scene) {
  var steps = 0;
  while (scene.moving && steps < 540) {
    scene.step();
    steps++;
  }
  expect(scene.moving, isFalse);
  return steps;
}

List<Offset> _vertices(PebblePose pose, double width) => [
  for (final p in pose.design.vertices)
    pose.center +
        Offset(
              p.dx * math.cos(pose.angle) - p.dy * math.sin(pose.angle),
              p.dx * math.sin(pose.angle) + p.dy * math.cos(pose.angle),
            ) *
            width,
];

void _expectContained(PebbleSimulation scene, {double tolerance = 2}) {
  final tray = scene.geometry.interior;
  final radius = PebbleDesign.radius * scene.geometry.pebbleWidth;
  for (final stone in scene.poses) {
    for (final point in _vertices(stone, scene.geometry.pebbleWidth)) {
      expect(
        point.dx,
        inInclusiveRange(
          tray.left + radius - tolerance,
          tray.right - radius + tolerance,
        ),
      );
      expect(point.dy + radius, lessThanOrEqualTo(tray.bottom + tolerance));
    }
  }
}

void _expectSeparated(PebbleSimulation scene) {
  final stones = scene.poses
      .map((pose) => _vertices(pose, scene.geometry.pebbleWidth))
      .toList();
  final radius = PebbleDesign.radius * scene.geometry.pebbleWidth;
  for (var i = 0; i < stones.length; ++i) {
    for (var j = i + 1; j < stones.length; ++j) {
      expect(_overlap(stones[i], stones[j]), lessThan(0));
      expect(
        math.min(
          _edgeDistance(stones[i], stones[j]),
          _edgeDistance(stones[j], stones[i]),
        ),
        greaterThan(2 * radius - 2),
      );
    }
  }
}

double _edgeDistance(List<Offset> vertices, List<Offset> polygon) {
  double dot(Offset a, Offset b) => a.dx * b.dx + a.dy * b.dy;
  var minimum = double.infinity;
  for (final vertex in vertices) {
    for (var i = 0; i < polygon.length; i++) {
      final start = polygon[i];
      final edge = polygon[(i + 1) % polygon.length] - start;
      final along = (dot(vertex - start, edge) / edge.distanceSquared).clamp(
        0.0,
        1.0,
      );
      minimum = math.min(minimum, (vertex - (start + edge * along)).distance);
    }
  }
  return minimum;
}

double _overlap(List<Offset> first, List<Offset> second) {
  var minimum = double.infinity;
  for (final polygon in [first, second]) {
    for (var i = 0; i < polygon.length; ++i) {
      final edge = polygon[(i + 1) % polygon.length] - polygon[i];
      final normal = Offset(-edge.dy, edge.dx) / edge.distance;
      double project(Offset point) =>
          normal.dx * point.dx + normal.dy * point.dy;
      final a = first.map(project).toList()..sort();
      final b = second.map(project).toList()..sort();
      minimum = math.min(
        minimum,
        math.min(a.last, b.last) - math.max(a.first, b.first),
      );
    }
  }
  return minimum;
}
