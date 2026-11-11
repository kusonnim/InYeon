import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itda_mobile/l10n/generated/app_localizations.dart';
import 'package:itda_mobile/models/content.dart';
import 'package:itda_mobile/widgets/content_details.dart';
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
      final summary = find.text('AI summary');
      expect(original, findsOneWidget);
      expect(
        tester.getTopLeft(original).dy,
        lessThan(tester.getTopLeft(summary).dy),
      );
      expect(find.text(note.analysis!.summary!), findsNothing);
      expect(find.text('Recommendations'), findsNothing);
      await tester.tap(summary);
      await tester.pumpAndSettle();
      expect(find.text(note.analysis!.summary!), findsOneWidget);
    },
  );

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
      final readMore = find.text('더 읽기').hitTestable();
      await tester.scrollUntilVisible(readMore, 180);
      expect(find.text('원문의 일부를 확인했어요'), findsOneWidget);
      expect(tester.widget<Text>(find.text(summary)).maxLines, 6);
      await tester.tap(readMore);
      await tester.pumpAndSettle();
      final expandedSummary = tester.widget<EditableText>(find.text(summary));
      expect(expandedSummary.readOnly, isTrue);
      expect(expandedSummary.maxLines, isNull);
      final coverage = find.text('원문 확인 범위').hitTestable();
      await tester.scrollUntilVisible(
        coverage,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(coverage);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text(limitation).hitTestable(), 160,
          scrollable: find.byType(Scrollable).first);
      expect(find.text(limitation), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Widget _page(
  ContentItem item, {
  Locale locale = const Locale('en'),
  bool dark = false,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: itdaTheme(dark ? Brightness.dark : Brightness.light),
  home: Scaffold(body: ContentDetails(content: item)),
);
