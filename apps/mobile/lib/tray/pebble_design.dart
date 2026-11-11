import 'dart:math' as math;
import 'dart:ui';

/// A normalized convex hull and rounding radius shared by Box2D and Flutter.
final class PebbleDesign {
  const PebbleDesign._(this.variant, this.color);

  factory PebbleDesign.forId(String id) {
    var hash = 0x811c9dc5;
    for (final unit in id.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return PebbleDesign._(hash % _hulls.length, (hash >> 8) % 6);
  }

  final int variant;
  final int color;

  static const radius = .105;
  List<Offset> get vertices => _hulls[variant];
  Path get silhouette => _silhouettes[variant];

  static const _hulls = [
    [Offset(-.028, -.405), Offset(.365, .183), Offset(-.333, .224)],
    [Offset(.018, -.420), Offset(.347, .221), Offset(-.356, .183)],
    [Offset(-.043, -.398), Offset(.378, .164), Offset(-.324, .244)],
    [Offset(.045, -.404), Offset(.322, .247), Offset(-.367, .176)],
    [Offset(-.011, -.415), Offset(.360, .200), Offset(-.346, .212)],
  ];
  static final _silhouettes = _hulls.map(_roundedHull).toList(growable: false);

  static Path _roundedHull(List<Offset> points) {
    // Box2D expands each hull edge by the radius and joins them with arcs
    // centered on the hull vertices. Construct that same offset boundary.
    final normals = [
      for (var i = 0; i < points.length; i++)
        (points[(i + 1) % points.length] - points[i]).direction - math.pi / 2,
    ];
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final start = normals[(i + points.length - 1) % points.length];
      path.arcTo(
        Rect.fromCircle(center: points[i], radius: radius),
        start,
        (normals[i] - start) % (2 * math.pi),
        i == 0,
      );
    }
    return path..close();
  }
}
