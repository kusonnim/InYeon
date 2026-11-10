import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
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
      expect(same.outline, designs[index].outline);
      expect(same.color, designs[index].color);
    }
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
      scene.drag(const Offset(-150, 700));
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
  for (final p in pose.design.outline)
    pose.center +
        Offset(
              p.dx * math.cos(pose.angle) - p.dy * math.sin(pose.angle),
              p.dx * math.sin(pose.angle) + p.dy * math.cos(pose.angle),
            ) *
            width,
];

void _expectContained(PebbleSimulation scene, {double tolerance = 2}) {
  final tray = scene.geometry.interior;
  for (final stone in scene.poses) {
    for (final point in _vertices(stone, scene.geometry.pebbleWidth)) {
      expect(
        point.dx,
        inInclusiveRange(tray.left - tolerance, tray.right + tolerance),
      );
      expect(point.dy, lessThanOrEqualTo(tray.bottom + tolerance));
    }
  }
}

void _expectSeparated(PebbleSimulation scene) {
  final stones = scene.poses
      .map((pose) => _vertices(pose, scene.geometry.pebbleWidth))
      .toList();
  for (var i = 0; i < stones.length; ++i) {
    for (var j = i + 1; j < stones.length; ++j) {
      expect(_overlap(stones[i], stones[j]), lessThan(2));
    }
  }
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
