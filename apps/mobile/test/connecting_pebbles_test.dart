import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itda_mobile/widgets/connecting_pebbles.dart';

void main() {
  testWidgets('pauses outside the viewport and while the app is inactive', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 120,
            child: SingleChildScrollView(
              controller: scroll,
              child: const Column(
                children: [
                  ConnectingPebbles(label: 'Organizing'),
                  SizedBox(height: 400),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isTrue);

    scroll.jumpTo(180);
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);

    scroll.jumpTo(0);
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('navigation mutes a covered animation and allows Back', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                const ConnectingPebbles(label: 'Organizing'),
                TextButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => Scaffold(appBar: AppBar()),
                    ),
                  ),
                  child: const Text('Open original'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.tap(find.text('Open original'));
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(find.text('Organizing'), findsNothing);

    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Organizing'), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
