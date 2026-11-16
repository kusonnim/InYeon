import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itda_mobile/l10n/generated/app_localizations.dart';
import 'package:itda_mobile/models/content.dart';
import 'package:itda_mobile/widgets/connecting_pebbles.dart';
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
      final archive = find.text('Archive');
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
      await _tap(tester, 'Show less');
      expect(summary, findsOneWidget);
      expect(second, findsNothing);
      expect(find.text('Open original'), findsNothing);
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'short content fills the detail viewport in ${dark ? 'dark' : 'light'} mode',
      (tester) async {
        _setViewport(
          tester,
          const Size(360, 640),
          safeArea: const FakeViewPadding(top: 24, bottom: 20),
        );
        final item = ContentItem.fromJson({
          ...examples[2],
          'title': 'Short note',
          'source_text': 'Remember the handout.',
        });
        await tester.pumpWidget(_page(item, dark: dark));
        await tester.pumpAndSettle();

        final layout = _detailLayout(tester);
        _expectFixedLayout(tester, layout, bottomInset: 20);
        expect(layout.card.height, greaterThan(400));
        expect(_cardScroll(tester).maxScrollExtent, 0);
        expect(
          tester.getTopLeft(find.text('Short note')).dy,
          layout.card.top + ItdaSpace.large,
        );
        final cardColor = itdaTheme(
          dark ? Brightness.dark : Brightness.light,
        ).colorScheme.surfaceContainerLow;
        final surface = find.byWidgetPredicate(
          (widget) => widget is Material && widget.color == cardColor,
        );
        expect(surface, findsOneWidget);
        expect(tester.getRect(surface), layout.card);
        expect(
          find.descendant(of: surface, matching: find.text('Archive')),
          findsNothing,
        );
        expect(
          find.descendant(of: surface, matching: find.text('Show details')),
          findsNothing,
        );

        await tester.tap(find.text('Show details'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 90));
        expect(_detailLayout(tester, toggle: 'Show less'), layout);
        await tester.pumpAndSettle();
        expect(_detailLayout(tester, toggle: 'Show less'), layout);
        await _tap(tester, 'Show less');
        expect(_detailLayout(tester), layout);
      },
    );
  }

  testWidgets('landscape detail respects side and gesture navigation insets', (
    tester,
  ) async {
    _setViewport(
      tester,
      const Size(640, 320),
      safeArea: const FakeViewPadding(top: 24, left: 22, right: 18, bottom: 16),
    );
    final item = ContentItem.fromJson(examples.first);
    await tester.pumpWidget(_page(item));
    await tester.pumpAndSettle();

    final layout = _detailLayout(tester);
    _expectFixedLayout(tester, layout, bottomInset: 16);
    expect(layout.card.left, 22 + ItdaSpace.page);
    expect(layout.card.right, 640 - 18 - ItdaSpace.page);
    await _tap(tester, 'Show details');
    expect(_detailLayout(tester, toggle: 'Show less'), layout);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail actions stay above an active portrait keyboard', (
    tester,
  ) async {
    _setViewport(
      tester,
      const Size(360, 640),
      safeArea: const FakeViewPadding(top: 24, bottom: 20),
    );
    final item = ContentItem.fromJson(examples.first);
    await tester.pumpWidget(_page(item));
    await tester.pumpAndSettle();

    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    tester.view.padding = const FakeViewPadding(top: 24);
    await tester.pumpAndSettle();
    final layout = _detailLayout(tester);
    _expectFixedLayout(tester, layout, bottomInset: 260);
    await _tap(tester, 'Show details');
    expect(_detailLayout(tester, toggle: 'Show less'), layout);
    expect(tester.takeException(), isNull);
  });

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
      expect(find.byType(ConnectingPebbles), findsNothing);
      expect(find.text(source), findsOneWidget);
      expect(find.text('Recommendations'), findsNothing);
      expect(find.text('Open original'), findsNothing);
      await _tap(tester, 'Show details');
      expect(find.text(source), findsOneWidget);
      expect(find.text('Open original'), findsOneWidget);
    });
  }

  for (final dark in [false, true]) {
    testWidgets(
      'processing and result keep card and footer fixed in ${dark ? 'dark' : 'light'} mode',
      (tester) async {
        _setViewport(
          tester,
          const Size(320, 640),
          safeArea: const FakeViewPadding(top: 24, bottom: 20),
        );
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        const source = 'The original notice remains accessible.';
        ContentItem waiting(String status) => ContentItem.fromJson({
          ...examples.first,
          'analysis': null,
          'analysis_status': status,
          'recommendations': <Object>[],
          'source_text': source,
        });
        await tester.pumpWidget(_page(waiting('pending'), dark: dark));
        await tester.pumpAndSettle();
        final layout = _detailLayout(tester);
        expect(find.text('Analysis pending'), findsOneWidget);
        expect(find.byType(ConnectingPebbles), findsNothing);

        await tester.pumpWidget(_page(waiting('processing'), dark: dark));
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.byType(ConnectingPebbles), findsOneWidget);
        expect(find.text('Organizing'), findsOneWidget);
        expect(find.text(source), findsOneWidget);
        expect(_detailLayout(tester), layout);

        // Elapsed animation time does not change the authoritative state.
        await tester.pump(const Duration(seconds: 4));
        expect(find.text('Organizing'), findsOneWidget);
        expect(find.text('Recommendations'), findsNothing);

        final completed = ContentItem.fromJson(examples.first);
        await tester.pumpWidget(_page(completed, dark: dark));
        await tester.pumpAndSettle();
        expect(find.byType(ConnectingPebbles), findsNothing);
        expect(find.text(completed.analysis!.summary!), findsOneWidget);
        expect(find.text(completed.recommendations.first.text), findsOneWidget);
        expect(_detailLayout(tester), layout);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('reduced motion keeps a static accessible processing status', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final item = ContentItem.fromJson({
        ...examples.first,
        'analysis': null,
        'analysis_status': 'processing',
        'recommendations': <Object>[],
      });
      await tester.pumpWidget(
        _page(item, locale: const Locale('ko'), reduceMotion: true),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ConnectingPebbles), findsOneWidget);
      expect(find.bySemanticsLabel('정리 중'), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isFalse);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('reduced motion reveals details immediately', (tester) async {
    final item = ContentItem.fromJson(examples.first);
    await tester.pumpWidget(_page(item, reduceMotion: true));
    await tester.pumpAndSettle();
    expect(find.byType(AnimatedSize), findsNothing);
    await _tap(tester, 'Show details');
    expect(find.text('Source coverage'), findsOneWidget);
  });

  testWidgets(
    'long Korean content scrolls inside a fixed card at 200% text size',
    (tester) async {
      _setViewport(
        tester,
        const Size(320, 520),
        safeArea: const FakeViewPadding(top: 24, bottom: 24),
      );
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final title = List.filled(5, '동네 기록을 모으는 워크숍 안내').join(' ');
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
      expect(find.byType(ConnectingPebbles), findsNothing);
      expect(find.text('추천'), findsNothing);
      expect(find.text('원문의 일부를 확인했어요'), findsNothing);
      expect(find.text('AI 요약'), findsNothing);
      expect(tester.widget<Text>(find.text(summary)).maxLines, 6);

      final layout = _detailLayout(tester, toggle: '상세히 보기', archive: '보관하기');
      _expectFixedLayout(tester, layout, bottomInset: 24);
      final scroll = _cardScroll(tester);
      await tester.dragFrom(layout.card.center, const Offset(0, -100));
      await tester.pumpAndSettle();
      final offset = scroll.pixels;
      expect(offset, greaterThan(0));
      expect(_detailLayout(tester, toggle: '상세히 보기', archive: '보관하기'), layout);

      await _tap(tester, '상세히 보기');
      expect(_detailLayout(tester, toggle: '접기', archive: '보관하기'), layout);
      expect(scroll.pixels, offset);
      final expandedSummary = tester.widget<EditableText>(find.text(summary));
      expect(expandedSummary.readOnly, isTrue);
      expect(expandedSummary.maxLines, isNull);
      expect(find.text(limitation), findsOneWidget);
      expect(find.text('원문의 일부를 확인했어요'), findsOneWidget);

      scroll.jumpTo(scroll.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(_detailLayout(tester, toggle: '접기', archive: '보관하기'), layout);
      final expandedEnd = scroll.pixels;
      await _tap(tester, '접기');
      expect(_detailLayout(tester, toggle: '상세히 보기', archive: '보관하기'), layout);
      expect(scroll.pixels, inInclusiveRange(0, scroll.maxScrollExtent));
      expect(scroll.pixels, lessThan(expandedEnd));
      expect(find.text(limitation), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

void _setViewport(
  WidgetTester tester,
  Size size, {
  required FakeViewPadding safeArea,
}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.padding = safeArea;
  tester.view.viewPadding = safeArea;
  addTearDown(tester.view.reset);
}

typedef _DetailLayout = ({Rect card, Rect disclosure, Rect archive});

_DetailLayout _detailLayout(
  WidgetTester tester, {
  String toggle = 'Show details',
  String archive = 'Archive',
}) {
  Rect button(String label) => tester.getRect(
    find
        .ancestor(
          of: find.text(label),
          matching: find.bySubtype<ButtonStyleButton>(),
        )
        .first,
  );
  return (
    card: tester.getRect(find.byType(SingleChildScrollView)),
    disclosure: button(toggle),
    archive: button(archive),
  );
}

void _expectFixedLayout(
  WidgetTester tester,
  _DetailLayout layout, {
  required double bottomInset,
}) {
  final appBar = tester.getRect(find.byType(AppBar));
  final screenBottom = tester.view.physicalSize.height;
  expect(layout.card.top, appBar.bottom + ItdaSpace.medium);
  expect(layout.disclosure.top, layout.card.bottom + ItdaSpace.tiny);
  expect(layout.disclosure.bottom, layout.archive.top);
  expect(layout.archive.bottom, screenBottom - bottomInset - ItdaSpace.tiny);
}

ScrollPosition _cardScroll(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byType(SingleChildScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

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
  home: Builder(
    builder: (context) {
      final copy = AppLocalizations.of(context);
      return Scaffold(
        appBar: AppBar(title: Text(copy.detailsTitle)),
        body: ContentDetails(
          content: item,
          primaryAction: FilledButton.icon(
            onPressed: () {},
            icon: const Icon(Icons.archive_outlined, size: 19),
            label: Text(copy.archiveAction),
          ),
        ),
      );
    },
  ),
);
