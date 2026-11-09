import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itda_mobile/api/fixture_content_api.dart';
import 'package:itda_mobile/main.dart';
import 'package:itda_mobile/models/content.dart';
import 'package:itda_mobile/native/share_bridge.dart';

void main() {
  testWidgets('fixture library opens content details without a worker',
      (tester) async {
    final api = FixtureContentApi(jsonDecode(
      File('assets/fixtures/catalog.json').readAsStringSync(),
    ) as Map<String, dynamic>);
    final first = (await api.listContents()).items.first;
    await tester.pumpWidget(ItdaApp(api: api));
    await tester.pumpAndSettle();
    expect(find.text(first.title ?? 'Untitled content'), findsOneWidget);
    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();
    expect(find.text('Original source'), findsOneWidget);
    expect(find.text('AI interpretation'), findsOneWidget);
  });

  testWidgets('resuming refreshes local shares separately from fixtures',
      (tester) async {
    final api = FixtureContentApi(jsonDecode(
      File('assets/fixtures/catalog.json').readAsStringSync(),
    ) as Map<String, dynamic>);
    final bridge = _TestShareBridge();
    await tester.pumpWidget(ItdaApp(api: api, shareBridge: bridge));
    await tester.pumpAndSettle();
    expect(find.text('Share from another app to save here.'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    bridge.items = [
      PendingShare(
        localId: 'new-local-item',
        inputType: InputType.url,
        label: 'https://example.org/shared',
        receivedAt: DateTime.utc(2026, 11, 9),
      ),
    ];
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.text('https://example.org/shared'), findsOneWidget);
    expect(find.text('Link · Pending upload'), findsOneWidget);
    expect(find.text(fixtureNotice), findsOneWidget);
  });
}

class _TestShareBridge implements ShareBridge {
  List<PendingShare> items = [];

  @override
  Future<List<PendingShare>> listPendingShares() async => items;
}
