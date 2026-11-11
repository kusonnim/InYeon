import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itda_mobile/l10n/generated/app_localizations.dart';
import 'package:itda_mobile/models/content.dart';
import 'package:itda_mobile/widgets/content_details.dart';
import 'package:itda_mobile/widgets/detail_card.dart';
import 'package:itda_mobile/widgets/itda_theme.dart';

void main() {
  late List<Map<String, dynamic>> examples;

  setUp(() {
    final catalog =
        jsonDecode(File('assets/fixtures/catalog.json').readAsStringSync())
            as Map<String, dynamic>;
    examples = (catalog['items'] as List).cast<Map<String, dynamic>>();
  });

  testWidgets(
    'a personal note leads with the original and omits empty recommendations',
    (tester) async {
      final note = ContentItem.fromJson(examples[2]);
      await tester.pumpWidget(_page(note));
      await tester.pumpAndSettle();
      final original = find.text(note.sourceText!);
      expect(original, findsOneWidget);
      expect(find.text(note.analysis!.summary!), findsNothing);
      expect(find.text('Recommendations'), findsNothing);
      await _tap(tester, 'Show details');
      expect(find.text(note.analysis!.summary!), findsOneWidget);
      expect(original, findsOneWidget);
      expect(find.text('More recommendations'), findsNothing);
      expect(find.text('Recommendations'), findsNothing);
    },
  );

  testWidgets(
    'a single card reveals provenance, source and additional recommendations',
    (tester) async {
      final item = ContentItem.fromJson(examples.first);
      await tester.pumpWidget(_page(item));
      await tester.pumpAndSettle();
      final card = find.byType(DetailCard);
      final title = find.text(item.title!);
      final summary = find.text(item.analysis!.summary!);
      final archive = find.text('Archive item');
      final second = find.text(item.recommendations.last.text);
      expect(card, findsOneWidget);
      expect(
        tester.getTopLeft(title).dy,
        lessThan(tester.getTopLeft(summary).dy),
      );
      expect(
        tester.getTopLeft(summary).dy,
        lessThan(tester.getTopLeft(archive).dy),
      );
      expect(find.textContaining('AI summary'), findsNothing);
      expect(find.text(item.recommendations.first.text), findsOneWidget);
      expect(second, findsNothing);
      expect(find.text('More recommendations'), findsNothing);
      expect(find.text('Open original'), findsNothing);
      expect(find.text('Source coverage'), findsNothing);
      expect(find.textContaining('Saved '), findsNothing);
      await _tap(tester, 'Show details');
      expect(card, findsOneWidget);
      expect(summary, findsOneWidget);
      expect(archive, findsOneWidget);
      expect(find.text('Open original'), findsOneWidget);
      expect(find.text('Source coverage'), findsOneWidget);
      expect(
        find.text('The summary was generated from the available source.'),
        findsOneWidget,
      );
      expect(find.text('More recommendations'), findsOneWidget);
      expect(second, findsOneWidget);
      expect(find.textContaining('Saved '), findsOneWidget);
      await _tap(tester, 'Hide details');
      expect(summary, findsOneWidget);
      expect(second, findsNothing);
      expect(find.text('Open original'), findsNothing);
    },
  );

  for (final (status, label) in [
    ('pending', 'Analysis pending'),
    ('failed', 'Analysis unavailable'),
  ]) {
    testWidgets('$status analysis keeps the saved original in the main card', (
      tester,
    ) async {
      const source = 'The saved excerpt is still available.';
      final item = ContentItem.fromJson({
        ...examples.first,
        'analysis': null,
        'analysis_status': status,
        'recommendations': <Object>[],
        'source_text': source,
      });
      await tester.pumpWidget(_page(item));
      await tester.pumpAndSettle();
      expect(find.text(label), findsOneWidget);
      expect(find.text(source), findsOneWidget);
      expect(find.text('Recommendations'), findsNothing);
      expect(find.text('Open original'), findsNothing);
      await _tap(tester, 'Show details');
      expect(find.text(source), findsOneWidget);
      expect(find.text('Open original'), findsOneWidget);
    });
  }

  testWidgets('reduced motion expands the card immediately', (tester) async {
    final item = ContentItem.fromJson(examples.first);
    await tester.pumpWidget(_page(item, reduceMotion: true));
    await tester.pumpAndSettle();
    expect(find.byType(AnimatedSize), findsNothing);
    await _tap(tester, 'Show details');
    expect(find.text('Source coverage'), findsOneWidget);
  });

  testWidgets(
    'a long Korean article keeps its full summary and coverage accessible',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final title = List.filled(3, '동네 기록을 모으는 워크숍 안내').join(' ');
      final summary = List.filled(
        10,
        '공개된 안내문에는 참가 신청이 필요하다고 적혀 있어요.',
      ).join(' ');
      const limitation = '공개된 발췌문에 장소와 마감일이 없어요.';
      final item = ContentItem.fromJson({
        ...examples[4],
        'title': title,
        'analysis': {
          ...examples[4]['analysis'] as Map<String, dynamic>,
          'summary': summary,
          'limitations': [limitation],
        },
        'recommendations': <Object>[],
      });
      await tester.pumpWidget(
        _page(item, locale: const Locale('ko'), dark: true),
      );
      await tester.pumpAndSettle();
      expect(find.text(title), findsOneWidget);
      expect(find.text('추천'), findsNothing);
      expect(find.text('원문의 일부를 확인했어요'), findsNothing);
      expect(find.text('AI 요약'), findsNothing);
      expect(tester.widget<Text>(find.text(summary)).maxLines, 6);
      await _tap(tester, '상세히 보기');
      final expandedSummary = tester.widget<EditableText>(find.text(summary));
      expect(expandedSummary.readOnly, isTrue);
      expect(expandedSummary.maxLines, isNull);
      expect(find.text(limitation), findsOneWidget);
      expect(find.text('원문의 일부를 확인했어요'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _tap(WidgetTester tester, String label) async {
  final target = find.text(label);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Widget _page(
  ContentItem item, {
  Locale locale = const Locale('en'),
  bool dark = false,
  bool reduceMotion = false,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: itdaTheme(dark ? Brightness.dark : Brightness.light),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
    child: child!,
  ),
  home: Scaffold(
    body: ContentDetails(
      content: item,
      primaryAction: FilledButton(
        onPressed: () {},
        child: const Text('Archive item'),
      ),
    ),
  ),
);
