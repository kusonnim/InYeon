import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../tray/pebble_design.dart';
import 'itda_theme.dart';

class ConnectingPebbles extends StatefulWidget {
  const ConnectingPebbles({super.key, required this.label});

  final String label;

  @override
  State<ConnectingPebbles> createState() => _ConnectingPebblesState();
}

class _ConnectingPebblesState extends State<ConnectingPebbles>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _phase = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );
  ScrollPosition? _scroll;
  bool _reduceMotion = false;
  bool _tickerEnabled = false;
  bool _foreground = true;
  bool _checkScheduled = false;

  @override
  void initState() {
    super.initState();
    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    final state = binding.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    final scroll = Scrollable.maybeOf(context)?.position;
    if (scroll != _scroll) {
      _scroll?.removeListener(_scheduleVisibilityCheck);
      _scroll = scroll;
      _scroll?.addListener(_scheduleVisibilityCheck);
    }
    if (_reduceMotion || !_tickerEnabled) _phase.stop();
    _scheduleVisibilityCheck();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _scheduleVisibilityCheck();
      WidgetsBinding.instance.ensureVisualUpdate();
    } else {
      _phase.stop();
    }
  }

  @override
  void didChangeMetrics() => _scheduleVisibilityCheck();

  void _scheduleVisibilityCheck() {
    if (_checkScheduled) return;
    _checkScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      if (!mounted) return;
      final animate =
          !_reduceMotion && _tickerEnabled && _foreground && _visible;
      if (animate == _phase.isAnimating) return;
      if (animate) {
        _phase.repeat();
      } else {
        _phase.stop();
      }
    });
  }

  bool get _visible {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    final viewport = RenderAbstractViewport.maybeOf(box);
    return viewport == null ||
        viewport.paintBounds.overlaps(
          MatrixUtils.transformRect(
            box.getTransformTo(viewport),
            box.paintBounds,
          ),
        );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scroll?.removeListener(_scheduleVisibilityCheck);
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    _scheduleVisibilityCheck();
    return Semantics(
      container: true,
      liveRegion: true,
      child: Row(
        children: [
          RepaintBoundary(
            child: SizedBox(
              width: 54,
              height: 24,
              child: CustomPaint(
                painter: _ConnectionPainter(
                  _reduceMotion ? null : _phase,
                  PebbleDesign.matteColor(theme.brightness, 0),
                  PebbleDesign.matteColor(theme.brightness, 2),
                  theme.colorScheme.outline,
                ),
              ),
            ),
          ),
          const SizedBox(width: ItdaSpace.small),
          Flexible(child: Text(widget.label, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}

class _ConnectionPainter extends CustomPainter {
  _ConnectionPainter(this.phase, this.circle, this.triangle, this.line)
    : super(repaint: phase);

  final Animation<double>? phase;
  final Color circle;
  final Color triangle;
  final Color line;

  @override
  void paint(Canvas canvas, Size size) {
    final t = phase?.value;
    final approach = t == null
        ? 1.0
        : const Interval(0, .37, curve: Curves.easeInOutCubic).transform(t) *
              (1 -
                  const Interval(
                    .68,
                    1,
                    curve: Curves.easeInOutCubic,
                  ).transform(t));
    final connection = t == null
        ? 1.0
        : const Interval(.24, .44, curve: Curves.easeInOut).transform(t) *
              (1 -
                  const Interval(
                    .61,
                    .84,
                    curve: Curves.easeInOut,
                  ).transform(t));
    final y = size.height / 2;
    final left = Offset(10 + 5 * approach, y);
    final right = Offset(size.width - 10 - 5 * approach, y);
    if (connection > 0) {
      canvas.drawLine(
        left,
        right,
        Paint()
          ..color = line.withValues(alpha: connection)
          ..strokeWidth = 1,
      );
    }
    canvas.drawCircle(
      left,
      PebbleDesign.circleRadius * 13,
      Paint()..color = circle,
    );
    canvas.save();
    canvas.translate(right.dx, right.dy);
    canvas.rotate(.21);
    canvas.scale(17);
    canvas.drawPath(
      PebbleDesign.triangleSilhouette(0),
      Paint()..color = triangle,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ConnectionPainter old) =>
      phase != old.phase ||
      circle != old.circle ||
      triangle != old.triangle ||
      line != old.line;
}
