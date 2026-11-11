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

  static const radius = .272;
  List<Offset> get vertices => _hulls[variant];
  Path get silhouette => _silhouettes[variant];

  // Alternate the three lobes with shallower points along the sides.
  static final _hulls = [
    _hull(-.52, [.229, .187, .218, .194, .232, .185]),
    _hull(-.19, [.221, .197, .228, .184, .217, .189]),
    _hull(-.78, [.233, .191, .216, .198, .225, .185]),
    _hull(.12, [.218, .181, .233, .191, .222, .198]),
    _hull(-.38, [.225, .194, .234, .190, .215, .184]),
  ];
  static final _silhouettes = _hulls.map(_roundedHull).toList(growable: false);

  static List<Offset> _hull(double phase, List<double> radii) =>
      List.unmodifiable([
        for (final (index, distance) in radii.indexed)
          Offset.fromDirection(phase + index * math.pi / 3, distance),
      ]);

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
