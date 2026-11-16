import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itda_mobile/tray/pebble_tray.dart';

const _first = (
  id: 'local:receipt',
  title: 'Repair cafe timetable',
  canArchive: true,
);
const _second = (
  id: 'server:two',
  title: 'Bus to the trailhead',
  canArchive: false,
);
const _third = (
  id: 'local:three',
  title: 'Portrait lighting notes',
  canArchive: false,
);

Finder _stone(String id) => find.byKey(ValueKey('pebble:$id'));

void main() {
  testWidgets(
    'home starts empty, settles, and preserves positions across a detail visit',
    (tester) async {
      final items = ValueNotifier<List<TrayItem>>([_first, _second, _third]);
      addTearDown(items.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ValueListenableBuilder(
              valueListenable: items,
              builder: (_, value, _) => Scaffold(
                body: _tray(
                  value,
                  open: (id) {
                    Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) =>
                            Scaffold(appBar: AppBar(title: Text('Opened $id'))),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      expect(_stone(_first.id), findsNothing);
      await _frames(tester, 15);
      expect(_stone(_first.id), findsOneWidget);
      expect(_stone(_third.id), findsNothing);
      await tester.pumpAndSettle();
      final settled = tester.getCenter(_stone(_first.id));
      expect(tester.binding.hasScheduledFrame, isFalse);

      await tester.tapAt(settled);
      await tester.pumpAndSettle();
      expect(find.text('Opened ${_first.id}'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(tester.getCenter(_stone(_first.id)), settled);

      items.value = [
        (id: 'local:new', title: 'Ceramics class notes', canArchive: false),
        ...items.value,
      ];
      await tester.pump();
      expect(tester.getCenter(_stone(_first.id)), settled);
      expect(_stone('local:new'), findsNothing);
      await tester.pumpAndSettle();
      expect(_stone('local:new'), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  testWidgets(
    'reduce motion presents a bounded resting tray and replaces the old scope',
    (tester) async {
      tester.view.physicalSize = const Size(244, 460);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final entries = List.generate(
        100,
        (index) => (
          id: 'account-a:$index',
          title: 'Field notebook $index',
          canArchive: false,
        ),
      );
      Widget app(String scope, List<TrayItem> entries) => MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: true,
              textScaler: const TextScaler.linear(2),
            ),
            child: Scaffold(body: _tray(entries, scope: scope)),
          ),
        ),
      );
      await tester.pumpWidget(app('account-a', entries));
      expect(_stone('account-a:0'), findsOneWidget);
      expect(_stone('account-a:5'), findsOneWidget);
      expect(_stone('account-a:6'), findsNothing);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(app('account-b', [_first]));
      expect(_stone('account-a:0'), findsNothing);
      expect(_stone(_first.id), findsOneWidget);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  testWidgets('circle drag and archive drop stay separate from tap', (
    tester,
  ) async {
    final dock = GlobalKey();
    final opened = <String>[];
    final archived = <String>[];
    final hover = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: _tray(
                  [_first, _second],
                  open: opened.add,
                  onArchive: archived.add,
                  hover: hover.add,
                  overDock: (pointer) {
                    final box =
                        dock.currentContext!.findRenderObject()! as RenderBox;
                    return (Offset.zero & box.size).contains(
                      box.globalToLocal(pointer),
                    );
                  },
                ),
              ),
              SizedBox(key: dock, width: 120, height: 48),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final origin = tester.getCenter(_stone(_first.id));
    final touch = await tester.startGesture(origin);
    await touch.moveBy(const Offset(0, -120));
    await _frames(tester, 18);
    expect(
      (tester.getCenter(_stone(_first.id)) - origin).distance,
      greaterThan(25),
    );
    await touch.moveTo(tester.getCenter(find.byKey(dock)));
    await _frames(tester, 3);
    expect(hover, [true]);
    await touch.up();
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(archived, [_first.id]);
    expect(hover, [true, false]);
  });
}

Widget _tray(
  List<TrayItem> items, {
  Object? scope,
  ValueChanged<String>? open,
  ValueChanged<String>? onArchive,
  ValueChanged<bool>? hover,
  bool Function(Offset)? overDock,
}) => PebbleTray(
  scope: scope,
  items: items,
  onOpen: open ?? (_) {},
  isOverArchive: overDock ?? (_) => false,
  onArchiveHover: hover ?? (_) {},
  onArchive: onArchive ?? (_) {},
);

Future<void> _frames(WidgetTester tester, int count) async {
  for (var frame = 0; frame < count; ++frame) {
    await tester.pump(const Duration(milliseconds: 17));
  }
}
