import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itda_mobile/api/fixture_content_api.dart';
import 'package:itda_mobile/main.dart';

void main() {
  testWidgets('fixture library opens content details without a worker', (tester) async {
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
}
