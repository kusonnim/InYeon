import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'pebble_design.dart';
import 'pebble_simulation.dart';

typedef TrayItem = ({String id, String title, bool canArchive});

class PebbleTray extends StatelessWidget {
  const PebbleTray({
    super.key,
    required this.scope,
    required this.items,
    required this.onOpen,
    required this.isOverArchive,
    required this.onArchiveHover,
    required this.onArchive,
  });

  final Object? scope;
  final List<TrayItem> items;
  final ValueChanged<String> onOpen;
  final bool Function(Offset) isOverArchive;
  final ValueChanged<bool> onArchiveHover;
  final ValueChanged<String> onArchive;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => _Scene(
      size: constraints.biggest,
      tray: this,
      reduceMotion: MediaQuery.disableAnimationsOf(context),
    ),
  );
}

class _Scene extends StatefulWidget {
  const _Scene({
    required this.size,
    required this.tray,
    required this.reduceMotion,
  });

  final Size size;
  final PebbleTray tray;
  final bool reduceMotion;

  @override
  State<_Scene> createState() => _SceneState();
}

class _SceneState extends State<_Scene> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  PebbleSimulation? _simulation;
  Map<String, TrayItem> _items = const {};
  bool _presented = false;
  bool _overArchive = false;
  bool _overDock = false;
  Duration _elapsed = Duration.zero;
  double _accumulator = 0;

  @override
  void initState() {
    super.initState();
    _reconcile(reset: true);
  }

  @override
  void didUpdateWidget(_Scene oldWidget) {
    super.didUpdateWidget(oldWidget);
    _reconcile(
      reset:
          widget.size != oldWidget.size ||
          widget.tray.scope != oldWidget.tray.scope,
    );
  }

  void _reconcile({required bool reset}) {
    final geometry = TrayGeometry(widget.size);
    if (reset) {
      _ticker.stop();
      _simulation?.dispose();
      _simulation = geometry.fits ? PebbleSimulation(geometry) : null;
    }
    final scene = _simulation;
    _items = {
      for (final item in widget.tray.items.take(geometry.capacity))
        item.id: item,
    };
    scene?.sync(_items.keys);
    if (scene?.draggedId == null) _overDock = false;
    if (scene?.draggedId == null && _overArchive) {
      _overArchive = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_overArchive) widget.tray.onArchiveHover(false);
      });
    }
    if (scene != null && _items.isNotEmpty) {
      if (scene.draggedId == null &&
          (widget.reduceMotion || (reset && _presented))) {
        scene.settle();
      }
      _presented = true;
    }
    _schedule();
  }

  void _schedule() {
    if (_simulation?.moving != true) {
      _ticker.stop();
    } else if (!_ticker.isActive) {
      _elapsed = Duration.zero;
      _accumulator = 0;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final scene = _simulation!;
    const step = PebbleSimulation.frameSeconds;
    final seconds =
        (elapsed - _elapsed).inMicroseconds / Duration.microsecondsPerSecond;
    _elapsed = elapsed;
    _accumulator = math.min(_accumulator + seconds, step * 4);
    var stepped = false;
    while (_accumulator >= step && scene.moving) {
      _accumulator -= step;
      scene.step();
      stepped = true;
    }
    if (stepped) setState(() {});
    _schedule();
  }

  Offset _local(Offset point) =>
      (context.findRenderObject()! as RenderBox).globalToLocal(point);

  void _pickUp(String id, Offset point) {
    if (_simulation?.pickUp(id, _local(point)) == true) _schedule();
  }

  void _drag(String id, Offset point) {
    final scene = _simulation;
    if (scene == null || scene.draggedId != id) return;
    scene.drag(_local(point));
    _overDock = widget.tray.isOverArchive(point);
    final overArchive = _items[id]?.canArchive == true && _overDock;
    if (overArchive != _overArchive) {
      _overArchive = overArchive;
      widget.tray.onArchiveHover(overArchive);
    }
    _schedule();
  }

  void _release(String id, {required bool drop}) {
    final scene = _simulation;
    if (scene == null || scene.draggedId != id) return;
    final archive = drop && _overDock;
    _overDock = false;
    scene.release();
    if (_overArchive) {
      _overArchive = false;
      widget.tray.onArchiveHover(false);
    }
    if (widget.reduceMotion) {
      scene.settle();
      setState(() {});
    }
    _schedule();
    if (archive) widget.tray.onArchive(id);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _simulation?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scene = _simulation;
    if (scene == null) return const SizedBox.expand();
    final theme = Theme.of(context);
    final width = scene.geometry.pebbleWidth;
    final bounds = Offset.zero & widget.size;
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
            painter: _TrayOutline(
              scene.geometry.interior,
              theme.colorScheme.outline,
            ),
          ),
          for (final pose in scene.poses)
            if (bounds.overlaps(
              Rect.fromCircle(center: pose.center, radius: width * .55),
            ))
              _Stone(
                key: ValueKey('pebble:${pose.id}'),
                pose: pose,
                title: _items[pose.id]!.title,
                width: width,
                onTap: () => widget.tray.onOpen(pose.id),
                onPickUp: (point) => _pickUp(pose.id, point),
                onDrag: (point) => _drag(pose.id, point),
                onDrop: () => _release(pose.id, drop: true),
                onCancel: () => _release(pose.id, drop: false),
              ),
        ],
      ),
    );
  }
}

class _Stone extends StatefulWidget {
  const _Stone({
    super.key,
    required this.pose,
    required this.title,
    required this.width,
    required this.onTap,
    required this.onPickUp,
    required this.onDrag,
    required this.onDrop,
    required this.onCancel,
  });

  final PebblePose pose;
  final String title;
  final double width;
  final VoidCallback onTap;
  final ValueChanged<Offset> onPickUp;
  final ValueChanged<Offset> onDrag;
  final VoidCallback onDrop;
  final VoidCallback onCancel;

  @override
  State<_Stone> createState() => _StoneState();
}

class _StoneState extends State<_Stone> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final pose = widget.pose;
    final width = widget.width;
    final half = width * .55;
    final theme = Theme.of(context);
    final textColor = theme.colorScheme.onSurface;
    final transform = Matrix4.identity()..translateByDouble(half, half, 0, 1);
    if (!pose.design.isCircle) transform.rotateZ(pose.angle);
    transform.scaleByDouble(width, width, 1, 1);
    final outline = pose.design.silhouette.transform(transform.storage);
    return Positioned(
      left: pose.center.dx - half,
      top: pose.center.dy - half,
      width: half * 2,
      height: half * 2,
      child: Semantics(
        container: true,
        label: widget.title,
        button: true,
        child: FocusableActionDetector(
          onShowFocusHighlight: (value) => setState(() => _focused = value),
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onTap();
                return null;
              },
            ),
          },
          child: GestureDetector(
            dragStartBehavior: DragStartBehavior.down,
            onTap: widget.onTap,
            onPanStart: (event) => widget.onPickUp(event.globalPosition),
            onPanUpdate: (event) => widget.onDrag(event.globalPosition),
            onPanEnd: (_) => widget.onDrop(),
            onPanCancel: widget.onCancel,
            child: CustomPaint(
              painter: _StoneOutline(
                outline,
                PebbleDesign.matteColor(theme.brightness, pose.design.color),
                _focused ? textColor : null,
              ),
              child: IgnorePointer(
                child: Center(
                  child: SizedBox(
                    width: width * .51,
                    child: ExcludeSemantics(
                      child: Text(
                        widget.title,
                        maxLines: width < 80 ? 1 : 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        textScaler: MediaQuery.textScalerOf(
                          context,
                        ).clamp(maxScaleFactor: 1.25),
                        style: TextStyle(
                          color: textColor,
                          fontSize: width < 84 ? 11 : 13,
                          fontWeight: FontWeight.w600,
                          height: 1.12,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StoneOutline extends CustomPainter {
  const _StoneOutline(this.path, this.fill, this.focus);

  final Path path;
  final Color fill;
  final Color? focus;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(path, Paint()..color = fill);
    if (focus case final color?) {
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool hitTest(Offset position) => path.contains(position);

  @override
  bool shouldRepaint(_StoneOutline oldDelegate) =>
      path != oldDelegate.path ||
      fill != oldDelegate.fill ||
      focus != oldDelegate.focus;
}

class _TrayOutline extends CustomPainter {
  const _TrayOutline(this.tray, this.color);

  final Rect tray;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(tray.left, tray.top)
      ..lineTo(tray.left, tray.bottom)
      ..lineTo(tray.right, tray.bottom)
      ..lineTo(tray.right, tray.top);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
  }

  @override
  bool shouldRepaint(_TrayOutline oldDelegate) =>
      tray != oldDelegate.tray || color != oldDelegate.color;
}
