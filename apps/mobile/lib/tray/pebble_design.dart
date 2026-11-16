import 'dart:math' as math;
import 'dart:ui';

import 'package:forge2d/forge2d.dart';

/// The painted outline and collision geometry for a stable library identity.
final class PebbleDesign {
  const PebbleDesign._(this.variant, this.color, {required this.isCircle});

  factory PebbleDesign.forId(String id) {
    var hash = 0x811c9dc5;
    for (final unit in id.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return PebbleDesign._(
      hash % _corners.length,
      (hash >> 8) % _light.length,
      isCircle: (hash >> 16) % 10 < 3,
    );
  }

  final int variant;
  final int color;
  final bool isCircle;

  static const circleRadius = .5;
  static const _cornerRadius = .105;
  static const _sideBow = .028;
  static final _circle = Path()
    ..addOval(Rect.fromCircle(center: Offset.zero, radius: circleRadius));

  double get fixtureRadius => isCircle ? circleRadius : _cornerRadius;
  List<Offset> get vertices => isCircle ? const [Offset.zero] : _hulls[variant];
  Path get silhouette => isCircle ? _circle : triangleSilhouette(variant);

  ShapeGeometry collisionShape(double width) {
    final radius = fixtureRadius * width;
    if (isCircle) return Circle(radius: radius);
    return Polygon([
      for (final point in vertices) Vector2(point.dx * width, point.dy * width),
    ], radius: radius);
  }

  static Path triangleSilhouette(int variant) => _triangles[variant];

  static Color matteColor(Brightness brightness, int index) =>
      (brightness == Brightness.dark ? _dark : _light)[index];

  static const _light = [
    Color(0xffc2c8ad),
    Color(0xffd5b7a4),
    Color(0xffd8c79e),
    Color(0xffadbfbc),
    Color(0xffc6b8c5),
    Color(0xffb8becb),
  ];
  static const _dark = [
    Color(0xff494f35),
    Color(0xff574235),
    Color(0xff62594c),
    Color(0xff465743),
    Color(0xff59483d),
    Color(0xff455360),
  ];

  static const _corners = [
    [Offset(-.028, -.405), Offset(.365, .183), Offset(-.333, .224)],
    [Offset(.018, -.420), Offset(.347, .221), Offset(-.356, .183)],
    [Offset(-.043, -.398), Offset(.378, .164), Offset(-.324, .244)],
    [Offset(.045, -.404), Offset(.322, .247), Offset(-.367, .176)],
    [Offset(-.011, -.415), Offset(.360, .200), Offset(-.346, .212)],
  ];
  static final _sides = [
    for (final triangle in _corners)
      [
        for (var i = 0; i < triangle.length; i++)
          _side(triangle[i], triangle[(i + 1) % triangle.length]),
      ],
  ];
  static final _hulls = [
    for (final (variant, triangle) in _corners.indexed)
      List<Offset>.unmodifiable([
        for (final (i, corner) in triangle.indexed) ...[
          corner,
          _sides[variant][i].midpoint,
        ],
      ]),
  ];
  static final _triangles = [
    for (final (variant, triangle) in _corners.indexed)
      _outline(triangle, _sides[variant]),
  ];

  static _Side _side(Offset from, Offset to) {
    final edge = to - from;
    final length = edge.distance;
    final outward = Offset(edge.dy, -edge.dx) / length;
    final chordMidpoint = (from + to) / 2;
    final arcRadius = edge.distanceSquared / (8 * _sideBow) + _sideBow / 2;
    final center = chordMidpoint - outward * (arcRadius - _sideBow);
    return (
      center: center,
      radius: arcRadius,
      start: (from - center).direction,
      end: (to - center).direction,
      midpoint: chordMidpoint + outward * _sideBow,
    );
  }

  static Path _outline(List<Offset> corners, List<_Side> sides) {
    // Expanding each side arc by the corner radius keeps its ends tangent to
    // the corner arcs. Box2D uses the same radius on the six sampled points.
    final path = Path();
    for (final (i, side) in sides.indexed) {
      final previous = sides[(i + sides.length - 1) % sides.length];
      path.arcTo(
        Rect.fromCircle(center: corners[i], radius: _cornerRadius),
        previous.end,
        (side.start - previous.end) % (2 * math.pi),
        i == 0,
      );
      path.arcTo(
        Rect.fromCircle(
          center: side.center,
          radius: side.radius + _cornerRadius,
        ),
        side.start,
        (side.end - side.start) % (2 * math.pi),
        false,
      );
    }
    return path..close();
  }
}

typedef _Side = ({
  Offset center,
  double radius,
  double start,
  double end,
  Offset midpoint,
});
