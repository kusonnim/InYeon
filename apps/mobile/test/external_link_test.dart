import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itda_mobile/l10n/generated/app_localizations.dart';
import 'package:itda_mobile/models/content.dart';
import 'package:itda_mobile/native/external_link.dart';
import 'package:itda_mobile/widgets/content_details.dart';

const _channel = MethodChannel('com.itda.itda_mobile/local_shares');
const _source = 'http://events.example.test/calendar?view=full%2Fwide#dates';
const _resource = 'https://www.youtube.com/watch?v=example';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final launches = <MethodCall>[];

  setUp(() {
    launches.clear();
    messenger.setMockMethodCallHandler(_channel, (call) async {
      launches.add(call);
      return true;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('opens ordinary HTTP, Instagram and YouTube URLs with the stored value',
      () async {
    const values = [_source, 'https://www.instagram.com/p/example/', _resource];
    for (final value in values) {
      final link = ExternalLink(value);
      expect(link.canOpen, isTrue);
      expect(await link.open(), isTrue);
    }
    expect(
        launches.map((call) => call.method), everyElement('openExternalLink'));
    expect(launches.map((call) => call.arguments), values);
  });

  test('rejects malformed and protected links before contacting Android',
      () async {
    for (final value in [
      '/calendar',
      'https:///calendar',
      'https://events.example.test:65536',
      'https://events.example.test/%ZZ',
      'file:///calendar',
      'intent://calendar#Intent;scheme=https;end',
      'https://demo@events.example.test/calendar',
      'https://objects.example.test/storage/v1/object/sign/content-assets/fixture',
      'https://events.example.test/#access%5Ftoken=placeholder',
    ]) {
      final link = ExternalLink(value);
      expect(link.canOpen, isFalse, reason: value);
      expect(await link.open(), isFalse);
    }
    expect(launches, isEmpty);
  });

  test('reports platform exceptions and a missing platform bridge', () async {
    messenger.setMockMethodCallHandler(
        _channel, (_) async => throw PlatformException(code: 'unavailable'));
    expect(await ExternalLink(_source).open(), isFalse);
    messenger.setMockMethodCallHandler(_channel, null);
    expect(await ExternalLink(_source).open(), isFalse);
  });

  testWidgets('a pending item can open and copy the original and a resource', (
    tester,
  ) async {
    final fixture =
        jsonDecode(File('assets/fixtures/catalog.json').readAsStringSync())
            as Map<String, dynamic>;
    final item = (fixture['items'] as List).first as Map<String, dynamic>;
    final recommendation =
        (item['recommendations'] as List).first as Map<String, dynamic>;
    final content = ContentItem.fromJson({
      ...item,
      'source_url': _source,
      'source_text': _source,
      'analysis_status': 'pending',
      'analysis': null,
      'recommendations': [
        {...recommendation, 'kind': 'resource', 'source_url': _resource},
        {...recommendation, 'source_url': null, 'text': 'No resource URL'},
      ],
    });
    final clipboard = <Object?>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard.add(call.arguments);
      return null;
    });
    await tester.pumpWidget(_page(ContentDetails(content: content)));
    await tester.pumpAndSettle();
    expect(launches, isEmpty);
    expect(find.text('Analysis pending'), findsOneWidget);
    expect(find.text(_source), findsNothing);
    await _tap(tester, 'Open original');
    await _tap(tester, 'Open resource');
    await _tap(tester, 'Copy link');
    await _tap(tester, 'Original source');
    final sourceSemantics = tester.getSemantics(find.text(_source));
    expect(sourceSemantics.label, _source);
    expect(sourceSemantics.rect.height, 48);
    await _tap(tester, _source);
    final sourceDisclosure = find.widgetWithText(
      ExpansionTile,
      'Original source',
    );
    await tester.tap(
      find
          .descendant(of: sourceDisclosure, matching: find.text('Copy link'))
          .hitTestable(),
    );
    await tester.pumpAndSettle();
    expect(launches.map((call) => call.arguments), [
      _source,
      _resource,
      _source,
    ]);
    expect(clipboard, [
      {'text': _resource},
      {'text': _source},
    ]);
    expect(find.text('No resource URL'), findsNothing);
    await _tap(tester, 'More recommendations');
    expect(find.text('No resource URL'), findsOneWidget);
  });

  testWidgets('a missing handler gives Korean feedback on the same screen',
      (tester) async {
    messenger.setMockMethodCallHandler(_channel, (_) async => false);
    await tester.pumpWidget(_page(
      const OriginalSource(url: _source),
      locale: const Locale('ko'),
    ));
    await tester.tap(find.text('원본 열기'));
    await tester.pumpAndSettle();
    expect(find.text('링크를 열 수 없어요'), findsOneWidget);
    expect(find.text('링크 복사'), findsOneWidget);
    expect(find.text(_source), findsOneWidget);
  });

  testWidgets('keeps protected source URLs out of the link actions',
      (tester) async {
    const url = 'https://example.test/#refresh_token=placeholder';
    await tester.pumpWidget(_page(
      const OriginalSource(text: 'Shared subject\n$url', url: url),
    ));
    expect(find.textContaining(url), findsNothing);
    expect(find.text('Open original'), findsNothing);
    expect(find.text('Copy link'), findsNothing);
    expect(find.textContaining('Shared subject'), findsOneWidget);
    expect(launches, isEmpty);
  });
}

Widget _page(Widget body, {Locale locale = const Locale('en')}) => MaterialApp(
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(body: body),
    );

Future<void> _tap(WidgetTester tester, String label) async {
  final target = find.text(label).hitTestable();
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(target, 160,
        scrollable: find.byType(Scrollable).first);
  }
  await tester.tap(target);
  await tester.pumpAndSettle();
}
