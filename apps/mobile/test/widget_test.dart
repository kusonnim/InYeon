import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itda_mobile/api/fixture_content_api.dart';
import 'package:itda_mobile/library/library_controller.dart';
import 'package:itda_mobile/main.dart';
import 'package:itda_mobile/models/content.dart';
import 'package:itda_mobile/native/catalog_bridge.dart';
import 'package:itda_mobile/native/language_preference.dart';
import 'package:itda_mobile/native/notification_bridge.dart';
import 'package:itda_mobile/native/share_bridge.dart';
import 'package:itda_mobile/widgets/connecting_pebbles.dart';

void main() {
  late Map<String, dynamic> fixture;
  late FixtureContentApi api;
  late _ShareAdapter shares;

  setUp(() {
    fixture =
        jsonDecode(File('assets/fixtures/catalog.json').readAsStringSync())
            as Map<String, dynamic>;
    api = FixtureContentApi(fixture);
    shares = _ShareAdapter();
    addTearDown(shares.events.close);
  });

  ContentItem example({
    String? title,
    String? owner,
    bool dismissed = false,
  }) {
    final raw = (fixture['items'] as List).first as Map<String, dynamic>;
    return ContentItem.fromJson({
      ...raw,
      if (title != null) 'title': title,
      if (owner != null) 'user_id': owner,
      if (dismissed)
        'notification': {
          ...raw['notification'] as Map<String, dynamic>,
          'visibility': 'dismissed'
        },
    });
  }

  testWidgets('defaults to Korean and restores an explicit language choice',
      (tester) async {
    tester.binding.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    final language = _LanguageAdapter();
    await tester.pumpWidget(ItdaApp(api: api, languagePreference: language));
    await tester.pumpAndSettle();
    expect(find.text('아직 저장한 콘텐츠가 없어요'), findsOneWidget);

    await tester.tap(find.byTooltip('계정'));
    await tester.pumpAndSettle();
    await _scrollTo(tester, '앱 언어');
    await tester.tap(find.byType(DropdownButton<Locale>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English').last);
    await tester.pumpAndSettle();
    expect(find.text('App language'), findsOneWidget);
    expect(await language.read(), const Locale('en'));

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(ItdaApp(
      api: api,
      initialLocale: await language.read(),
      languagePreference: language,
    ));
    await tester.pumpAndSettle();
    expect(find.text('Nothing saved yet'), findsOneWidget);
    await tester.tap(find.byTooltip('Account'));
    await tester.pumpAndSettle();
    await _scrollTo(tester, 'App language');
    await tester.tap(find.byType(DropdownButton<Locale>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('한국어').last);
    await tester.pumpAndSettle();
    expect(find.text('앱 언어'), findsOneWidget);
    expect(await language.read(), const Locale('ko'));
  });

  testWidgets(
    'groups exact repeated links and opens the individual originals',
    (tester) async {
      const first = 'https://example.org/events?season=winter';
      const other = 'https://example.org/events?season=spring';
      shares
        ..mode = UploadMode.mock
        ..items = [
          _local('a', first, type: InputType.url, subject: 'Winter workshop'),
          _local(
            'b',
            first,
            type: InputType.url,
            linkText: 'Repair cafe schedule\n' + first,
          ),
          _local('c', other, type: InputType.url, subject: 'Spring workshop'),
        ];
      await tester.pumpWidget(
        ItdaApp(
          initialLocale: const Locale('en'),
          api: api,
          shareBridge: shares,
        ),
      );
      await tester.pumpAndSettle();
      for (final id in ['a', 'b', 'c']) {
        expect(find.byKey(ValueKey('pebble:local:$id')), findsOneWidget);
      }
      await tester.tap(find.text('All saved'));
      await tester.pumpAndSettle();
      expect(find.text('2 saves of this link'), findsOneWidget);
      expect(find.text('Spring workshop'), findsOneWidget);
      expect(find.byKey(const ValueKey('local:a')), findsNothing);
      await tester.tap(find.byTooltip('Search saved items'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'repair cafe');
      await tester.pumpAndSettle();
      expect(find.text('Spring workshop'), findsNothing);
      await tester.tap(find.text('2 saves of this link'));
      await tester.pumpAndSettle();
      final original = find.byKey(const ValueKey('local:a'));
      final title = find
          .descendant(of: original, matching: find.text('Winter workshop'))
          .hitTestable();
      await tester.scrollUntilVisible(
        title,
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(title);
      await tester.pumpAndSettle();
      expect(shares.opened, ['a']);
      expect(find.text('Winter workshop'), findsOneWidget);
    await _expandDetails(tester);
      expect(find.text(first), findsOneWidget);
    },
  );

  testWidgets(
    'shows an empty private library and opens clearly labeled sample details',
    (tester) async {
      final first = example();
      await tester.pumpWidget(
        ItdaApp(initialLocale: const Locale('en'), api: api),
      );
      await tester.pumpAndSettle();
      expect(find.text('Nothing saved yet'), findsOneWidget);
      expect(find.text(first.title!), findsNothing);
      await tester.tap(find.text('Explore sample library'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(first.title!));
      await tester.pumpAndSettle();
      expect(find.text('Samples'), findsNothing);
      expect(find.text(first.analysis!.summary!), findsOneWidget);
      expect(find.text('AI summary'), findsNothing);
      await _expandDetails(tester);
      expect(find.text('Samples'), findsOneWidget);
      await _scrollTo(tester, 'Original source');
      expect(find.text('Original source'), findsOneWidget);
    },
  );

  testWidgets('labels staging and shows its API host before sign-in', (
    tester,
  ) async {
    final inbox = LocalInbox.fromMessage({
      'mode': 'staging',
      'shares': <Object?>[],
      'staging_api_host': 'api.staging.example.test',
    });
    shares
      ..mode = inbox.mode
      ..stagingApiHost = inbox.stagingApiHost;
    await tester.pumpWidget(
      ItdaApp(initialLocale: const Locale('en'), api: api, shareBridge: shares),
    );
    await tester.pumpAndSettle();
    expect(find.text('Staging mode'), findsOneWidget);
    expect(find.text('Mock mode'), findsNothing);
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsNWidgets(2));
    expect(find.text('App language'), findsNothing);
    await tester.tap(find.text('Account settings'));
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsNothing);
    expect(find.text('API host api.staging.example.test'), findsOneWidget);
    expect(
      find.text('Use an approved staging account and synthetic content.'),
      findsOneWidget,
    );
  });

  testWidgets('signed-out home opens sign-in directly and Back returns to home',
      (tester) async {
    final response = Completer<void>();
    shares
      ..mode = UploadMode.mock
      ..signInGate = response.future
      ..signInError = 'invalid_sign_in';
    await tester.pumpWidget(ItdaApp(
      initialLocale: const Locale('en'),
      api: api,
      shareBridge: shares,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsNWidgets(2));
    expect(find.text('App language'), findsNothing);
    await tester.enterText(find.byType(TextFormField).first, 'a@example.test');
    await tester.enterText(find.byType(TextFormField).last, 'synthetic');
    final submit = find.widgetWithText(FilledButton, 'Sign in');
    await tester.tap(submit);
    await tester.pump();
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    expect(find.bySemanticsLabel('Signing in'), findsOneWidget);
    response.complete();
    await tester.pumpAndSettle();
    expect(find.text('Could not verify your email and password.'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('잇다'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    shares
      ..signInError = null
      ..nextAccount = _account('a');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'a@example.test');
    await tester.enterText(find.byType(TextFormField).last, 'synthetic');
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.text('잇다'), findsOneWidget);
    expect(find.byTooltip('Account'), findsOneWidget);
  });

  testWidgets(
      'reads new local shares on resume and opens the saved original offline',
      (tester) async {
    const channel = MethodChannel('com.itda.itda_mobile/local_shares');
    final messenger = tester.binding.defaultBinaryMessenger;
    final launched = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      launched.add(call);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    shares.mode = UploadMode.live;
    await tester.pumpWidget(ItdaApp(
        initialLocale: const Locale('en'), api: api, shareBridge: shares));
    await tester.pumpAndSettle();
    expect(find.text('Nothing saved yet'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    shares.items = [
      _local('new-item', 'https://example.org/shared', type: InputType.url)
    ];
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.text('Link from example.org'), findsOneWidget);
    await _tapPebble(tester, 'local:new-item');
    await tester.pumpAndSettle();
    expect(find.text('Waiting to sync'), findsOneWidget);
    expect(find.text('Open original'), findsNothing);
    await _expandDetails(tester);
    expect(find.text('Original source'), findsOneWidget);
    expect(find.text('https://example.org/shared'), findsOneWidget);
    await _scrollTo(tester, 'Open original');
    await tester.tap(find.text('Open original').hitTestable());
    await tester.pumpAndSettle();
    expect(launched.single.method, 'openExternalLink');
    expect(launched.single.arguments, 'https://example.org/shared');
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(find.text('Content details'), findsOneWidget);
    expect(find.text('https://example.org/shared'), findsOneWidget);
  });

  testWidgets('tapping a title focuses it and saves the change to the library',
      (tester) async {
    final raw = (fixture['items'] as List).first as Map<String, dynamic>;
    final item = ContentItem.fromJson({
      ...raw,
      'title': 'Saved title',
      'user_note': 'Saved personal note',
    });
    final updated = ContentItem.fromJson({
      ...raw,
      'title': 'Revised title',
      'user_note': item.userNote,
      'version': item.version + 1,
    });
    shares
      ..mode = UploadMode.mock
      ..account = _account(item.userId);
    final catalog = _CatalogAdapter((_, __) async =>
        CatalogSnapshot(items: [item], phase: CatalogPhase.current));
    final details = _DetailsAdapter(item, editedItem: updated);
    await tester.pumpWidget(ItdaApp(
      initialLocale: const Locale('en'),
      api: api,
      shareBridge: shares,
      catalogBridge: catalog,
      notificationBridge: details,
    ));
    await tester.pumpAndSettle();
    await _tapPebble(tester, 'server:${item.id}');
    await tester.pumpAndSettle();
    final editTitle = find.byTooltip('Edit title');
    final titleSemantics = tester.getSemantics(editTitle);
    expect(titleSemantics.label, 'Edit title\nSaved title');
    expect(titleSemantics.rect.height, tester.getSize(editTitle).height);
    await tester.tap(find.text('Saved title'));
    await tester.pumpAndSettle();
    final fields =
        tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields.first.focusNode!.hasFocus, isTrue);
    expect(fields.first.controller!.text, item.title);
    expect(fields.last.controller!.text, item.userNote);
    await tester.enterText(find.byType(TextField).first, 'Revised title');
    await tester.pumpAndSettle();
    await _scrollTo(tester, 'Save changes');
    await tester.tap(find.text('Save changes').hitTestable());
    await tester.pumpAndSettle();
    expect(details.patch!.toJson(),
        {'expected_version': item.version, 'title': 'Revised title'});
    expect(find.text('Content details'), findsOneWidget);
    expect(find.text('Revised title'), findsOneWidget);

    await _expandDetails(tester);
    await _scrollTo(tester, 'Saved personal note');
    await tester.tap(find.text('Saved personal note').hitTestable());
    await tester.pumpAndSettle();
    final notes = tester.widget<TextField>(find.byType(TextField).last);
    expect(notes.focusNode!.hasFocus, isTrue);
    expect(notes.controller!.text, item.userNote);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Content details'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('잇다'), findsOneWidget);
    expect(find.text('Revised title'), findsOneWidget);
    expect(find.text('Saved title'), findsNothing);
  });

  testWidgets(
      'assigns a local original only after confirming the displayed account',
      (tester) async {
    shares
      ..mode = UploadMode.mock
      ..account = const UploadAccount(
          id: 'account-a', email: 'a@example.test', realm: 'mock')
      ..items = [
        _local('legacy-id', 'Saved before sign-in',
            state: LocalUploadState.authenticationRequired, canAssign: true),
      ];
    await tester.pumpWidget(ItdaApp(
        initialLocale: const Locale('en'), api: api, shareBridge: shares));
    await tester.pumpAndSettle();
    await _tapPebble(tester, 'local:legacy-id');
    await tester.pumpAndSettle();
    expect(shares.assigned, isNull);
    await _scrollTo(tester, 'Choose account');
    await tester.tap(find.text('Choose account').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('This item will be uploaded to a@example.test.'),
        findsOneWidget);
    expect(shares.assigned, isNull);
    await tester.tap(find.text('Sync to this account'));
    await tester.pumpAndSettle();
    expect(shares.assigned, ('legacy-id', 'account-a'));
  });

  testWidgets(
    'merges a receipt and its dismissed server item into one openable pebble',
    (tester) async {
      final item = example(dismissed: true);
      shares
        ..mode = UploadMode.mock
        ..account = _account(item.userId)
        ..items = [
          _local(
            'registered',
            'Local preview',
            state: LocalUploadState.synchronized,
            serverId: item.id,
          ),
        ];
      final catalog = _CatalogAdapter(
        (_, __) async =>
            CatalogSnapshot(items: [item], phase: CatalogPhase.current),
      );
      await tester.pumpWidget(
        ItdaApp(
          initialLocale: const Locale('en'),
          api: api,
          shareBridge: shares,
          catalogBridge: catalog,
          notificationBridge: _DetailsAdapter(item),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('pebble:local:registered')),
        findsOneWidget,
      );
      expect(find.byKey(ValueKey('pebble:server:${item.id}')), findsNothing);
      expect(find.text(item.title!), findsOneWidget);
      expect(find.text('Local preview'), findsNothing);
      expect(find.textContaining('AI summary'), findsNothing);
      expect(
        find.textContaining(item.recommendations.first.text),
        findsNothing,
      );
      await tester.tap(find.text('All saved'));
      await tester.pumpAndSettle();
      expect(find.text('Synced'), findsNothing);
      await tester.tap(find.text(item.title!));
      await tester.pumpAndSettle();
      expect(find.text('Content details'), findsOneWidget);
      await _expandDetails(tester);
      await _scrollTo(tester, 'Notification dismissed');
      expect(find.text('Notification dismissed'), findsOneWidget);
      expect(find.text('Restore notification'), findsNothing);
    },
  );

  testWidgets(
      'keeps local items available through connection errors and a retry',
      (tester) async {
    final item = example();
    shares
      ..mode = UploadMode.live
      ..account = _account(item.userId)
      ..items = [_local('waiting', 'A saved note')];
    var connected = false;
    final catalog = _CatalogAdapter((_, __) async {
      if (!connected) {
        return const CatalogSnapshot(
            items: [], phase: CatalogPhase.offline, initialized: false);
      }
      return CatalogSnapshot(items: [item], phase: CatalogPhase.current);
    });
    await tester.pumpWidget(ItdaApp(
        initialLocale: const Locale('en'),
        api: api,
        shareBridge: shares,
        catalogBridge: catalog));
    await tester.pumpAndSettle();
    expect(find.text('Connection unavailable'), findsOneWidget);
    expect(find.text('A saved note'), findsOneWidget);
    connected = true;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(catalog.syncRequests, 1);
    expect(find.text('Connection unavailable'), findsNothing);
    expect(find.byKey(const ValueKey('pebble:local:waiting')), findsOneWidget);
    expect(find.byKey(ValueKey('pebble:server:${item.id}')), findsOneWidget);
  });

  testWidgets('acknowledging a local receipt keeps the same stone and pose',
      (tester) async {
    final item = example(title: 'Confirmed collection item');
    var acknowledged = false;
    shares
      ..mode = UploadMode.mock
      ..account = _account(item.userId)
      ..items = [_local('receipt', 'Shared notebook')];
    final catalog = _CatalogAdapter((_, __) async => CatalogSnapshot(
          items: acknowledged ? [item] : [],
          phase: CatalogPhase.current,
        ));
    await tester.pumpWidget(ItdaApp(
      initialLocale: const Locale('en'),
      api: api,
      shareBridge: shares,
      catalogBridge: catalog,
      notificationBridge: _DetailsAdapter(item),
    ));
    await tester.pumpAndSettle();
    final stone = find.byKey(const ValueKey('pebble:local:receipt'));
    final position = tester.getCenter(stone);
    acknowledged = true;
    shares.items = [
      _local('receipt', 'Shared notebook',
          state: LocalUploadState.synchronized, serverId: item.id)
    ];
    shares.events.add(null);
    await tester.pumpAndSettle();
    expect(tester.getCenter(stone), position);
    expect(find.text(item.title!), findsOneWidget);
    expect(find.byKey(ValueKey('pebble:server:${item.id}')), findsNothing);
  });

  testWidgets('a queued local share keeps its upload status and opens without motion', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    shares
      ..mode = UploadMode.mock
      ..account = _account('a')
      ..items = [_local('receipt', 'Shared notebook')];
    await tester.pumpWidget(ItdaApp(
      initialLocale: const Locale('en'),
      api: api,
      shareBridge: shares,
    ));
    await tester.pumpAndSettle();
    await _tapPebble(tester, 'local:receipt');
    await tester.pumpAndSettle();
    expect(find.text('Waiting to sync'), findsOneWidget);
    expect(find.byType(ConnectingPebbles), findsNothing);
    final route = ModalRoute.of(tester.element(find.text('Content details')))!;
    expect(route.transitionDuration, Duration.zero);
    expect(route.reverseTransitionDuration, Duration.zero);
  });

  testWidgets('open details follow newer analysis results from the scoped library', (
    tester,
  ) async {
    final raw = (fixture['items'] as List).first as Map<String, dynamic>;
    final completed = ContentItem.fromJson({...raw, 'version': 3});
    ContentItem waiting(String status, int version) => ContentItem.fromJson({
      ...raw,
      'analysis': null,
      'analysis_status': status,
      'recommendations': <Object>[],
      'version': version,
    });
    final pending = waiting('pending', 1);
    var snapshot = pending;
    shares
      ..mode = UploadMode.mock
      ..account = _account(pending.userId);
    final catalog = _CatalogAdapter((_, __) async => CatalogSnapshot(
      items: [snapshot],
      phase: CatalogPhase.current,
    ));
    await tester.pumpWidget(ItdaApp(
      initialLocale: const Locale('en'),
      api: api,
      shareBridge: shares,
      catalogBridge: catalog,
      notificationBridge: _DetailsAdapter(pending),
    ));
    await tester.pumpAndSettle();
    await _tapPebble(tester, 'server:${pending.id}');
    await tester.pumpAndSettle();
    final route = ModalRoute.of(tester.element(find.text('Content details')))!;
    expect(route.transitionDuration, const Duration(milliseconds: 200));
    expect(route.reverseTransitionDuration, const Duration(milliseconds: 160));
    expect(find.text('Analysis pending'), findsOneWidget);

    snapshot = waiting('processing', 2);
    shares.events.add(null);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.byType(ConnectingPebbles), findsOneWidget);
    final edit = find.byWidgetPredicate((widget) =>
        widget is IconButton && widget.tooltip == 'Edit');
    expect(tester.widget<IconButton>(edit).onPressed, isNotNull);
    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Archive')).onPressed,
      isNotNull,
    );

    snapshot = completed;
    shares.events.add(null);
    await tester.pumpAndSettle();
    expect(find.byType(ConnectingPebbles), findsNothing);
    expect(find.text(completed.analysis!.summary!), findsOneWidget);
    expect(find.text(completed.recommendations.first.text), findsOneWidget);
    snapshot = pending;
    shares.events.add(null);
    await tester.pumpAndSettle();
    expect(find.text('Analysis pending'), findsNothing);
    expect(find.text(completed.analysis!.summary!), findsOneWidget);
  });

  testWidgets('the complete list reaches originals beyond the tray limit',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    shares.items = List.generate(32, (index) {
      final suffix = index.toString().padLeft(2, '0');
      return _local('notebook-$suffix', 'Workshop notebook $suffix');
    });
    await tester.pumpWidget(ItdaApp(
        initialLocale: const Locale('en'), api: api, shareBridge: shares));
    await tester.pumpAndSettle();
    expect(find.text('Workshop notebook 00'), findsNothing);
    await tester.tap(find.text('All saved'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Workshop notebook 00'), 340,
        maxScrolls: 30);
    await tester.tap(find.text('Workshop notebook 00'));
    await tester.pumpAndSettle();
    expect(shares.opened, ['notebook-00']);
    expect(find.text('Content details'), findsOneWidget);
  });

  testWidgets(
    'local workflow intent explains synchronization without editing',
    (tester) async {
      shares.items = [_local('unsynced', 'Planting schedule')];
      await tester.pumpWidget(
        ItdaApp(
          initialLocale: const Locale('en'),
          api: api,
          shareBridge: shares,
        ),
      );
      await tester.pumpAndSettle();
      await _tapPebble(tester, 'local:unsynced');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Archive').hitTestable());
      await tester.pumpAndSettle();
      expect(
        find.text('Sync this item before changing its status.'),
        findsOneWidget,
      );
      expect(find.text('Planting schedule'), findsWidgets);
      expect(find.text('Return to tray'), findsNothing);
    },
  );

  testWidgets(
    'pending pebbles archive in one confirmed PATCH and restore to pending',
    (tester) async {
      final raw = Map<String, dynamic>.of(
        (fixture['items'] as List).first as Map<String, dynamic>,
      );
      final server = _WorkflowAdapter(raw);
      final item = server.item;
      shares
        ..mode = UploadMode.mock
        ..account = _account(item.userId);
      final catalog = _CatalogAdapter(
        (_, __) async =>
            CatalogSnapshot(items: [server.item], phase: CatalogPhase.current),
      );
      await tester.pumpWidget(
        ItdaApp(
          initialLocale: const Locale('en'),
          api: api,
          shareBridge: shares,
          catalogBridge: catalog,
          notificationBridge: server,
        ),
      );
      await tester.pumpAndSettle();
      final stone = find.byKey(ValueKey('pebble:server:${item.id}'));
      server.editError = 'http_503';
      await _dropOnArchive(tester, stone);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('The change could not be confirmed'),
        findsOneWidget,
      );
      expect(stone, findsOneWidget);
      expect(server.item.workflowStatus, WorkflowStatus.pending);
      server.editError = null;
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      final acknowledgment = Completer<void>();
      server.editGate = acknowledgment.future;
      await _dropOnArchive(tester, stone);
      await tester.pump();
      expect(server.patch!.toJson(), {
        'expected_version': item.version,
        'workflow_status': 'archived',
      });
      expect(stone, findsOneWidget);
      expect(find.text('Moved to archive.'), findsNothing);
      expect(server.item.workflowStatus, WorkflowStatus.pending);

      acknowledgment.complete();
      await tester.pumpAndSettle();
      expect(stone, findsNothing);
      expect(server.item.workflowStatus, WorkflowStatus.archived);
      expect(server.item.version, item.version + 1);
      expect(server.item.analysisStatus, item.analysisStatus);
      expect(server.item.notification.visibility, item.notification.visibility);
      expect(server.item.notification.generation, item.notification.generation);
      expect(find.text('Moved to archive.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Archive'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(item.title!));
      await tester.pumpAndSettle();
      await _scrollTo(tester, 'Return to tray');
      await tester.tap(find.text('Return to tray').hitTestable());
      await tester.pumpAndSettle();
      expect(server.patch!.toJson(), {
        'expected_version': item.version + 1,
        'workflow_status': 'pending',
      });
      expect(server.item.userNote, item.userNote);
      expect(server.item.sourceUrl, item.sourceUrl);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Nothing archived yet'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(stone, findsOneWidget);
    },
  );

  for (final initial in ['pending', 'completed']) {
    testWidgets('detail archives $initial with a fresh version and one PATCH', (
      tester,
    ) async {
      final server = _WorkflowAdapter({
        ...(fixture['items'] as List).first as Map<String, dynamic>,
        'workflow_status': initial,
      });
      final item = server.item;
      shares
        ..mode = UploadMode.mock
        ..account = _account(item.userId);
      final catalog = _CatalogAdapter(
        (_, __) async =>
            CatalogSnapshot(items: [server.item], phase: CatalogPhase.current),
      );
      await tester.pumpWidget(
        ItdaApp(
          initialLocale: const Locale('en'),
          api: api,
          shareBridge: shares,
          catalogBridge: catalog,
          notificationBridge: server,
        ),
      );
      await tester.pumpAndSettle();
      final stone = find.byKey(ValueKey('pebble:server:${item.id}'));
      await tester.tapAt(tester.getCenter(stone));
      await tester.pumpAndSettle();
      final archive = find.text('Archive');
      server.advanceVersion();
      await tester.tap(archive);
      await tester.pumpAndSettle();
      expect(server.item.workflowStatus.name, initial);
      expect(find.textContaining('This item changed.'), findsOneWidget);
      await tester.tap(find.text('Load latest version'));
      await tester.pumpAndSettle();
      final before = server.edits;
      await tester.tap(archive);
      await tester.pumpAndSettle();
      expect(server.edits, before + 1);
      expect(server.patch!.toJson(), {
        'expected_version': item.version + 1,
        'workflow_status': 'archived',
      });
      expect(server.item.workflowStatus, WorkflowStatus.archived);
      expect(find.text('Return to tray'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(stone, findsNothing);
    });
  }

  testWidgets(
      'signing out and signing in replaces the previous account catalog',
      (tester) async {
    final itemA = example(title: 'Account A item', owner: 'a');
    final itemB = example(title: 'Account B item', owner: 'b');
    final archivedA = ContentItem.fromJson({
      ...(fixture['items'] as List)[1] as Map<String, dynamic>,
      'user_id': 'a',
      'title': 'Account A archive',
      'workflow_status': 'archived',
    });
    shares
      ..mode = UploadMode.mock
      ..account = _account('a')
      ..nextAccount = _account('b');
    final catalog = _CatalogAdapter((scope, _) async => CatalogSnapshot(
        items: scope.ownerId == 'a' ? [itemA, archivedA] : [itemB],
        phase: CatalogPhase.current));
    await tester.pumpWidget(ItdaApp(
        initialLocale: const Locale('en'),
        api: api,
        shareBridge: shares,
        catalogBridge: catalog));
    await tester.pumpAndSettle();
    expect(find.text('Account A item'), findsOneWidget);
    expect(find.text('Account A archive'), findsNothing);
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    expect(find.text('Account A archive'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Account'));
    await tester.pumpAndSettle();
    expect(find.text('Signed in'), findsOneWidget);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Signed out'), findsOneWidget);
    expect(find.text('a@example.test'), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsNWidgets(2));
    await tester.enterText(find.byType(TextFormField).first, 'b@example.test');
    await tester.enterText(find.byType(TextFormField).last, 'synthetic');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('b@example.test'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Account A item'), findsNothing);
    expect(find.text('Account B item'), findsOneWidget);
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing archived yet'), findsOneWidget);
    expect(find.text('Account A archive'), findsNothing);
  });

  test(
      'a slow account A snapshot cannot replace B, and recovery preserves B items',
      () async {
    final itemA = example(title: 'Account A item', owner: 'a');
    final itemB = example(title: 'Account B item', owner: 'b');
    shares.account = _account('a');
    final a = Completer<CatalogSnapshot>();
    final requestedA = Completer<void>();
    final catalog = _CatalogAdapter((scope, limit) {
      if (scope.ownerId == 'a') {
        requestedA.complete();
        return a.future;
      }
      return Future.value(CatalogSnapshot(
        items: [itemB],
        phase: limit > 10 ? CatalogPhase.retrying : CatalogPhase.current,
        hasMore: limit == 10,
      ));
    });
    final controller = LibraryController(shares, catalog);
    addTearDown(controller.dispose);
    final previous = controller.reload();
    await requestedA.future;
    shares.account = _account('b');
    await controller.reload();
    a.complete(CatalogSnapshot(items: [itemA], phase: CatalogPhase.current));
    await previous;
    expect(controller.entries.single.remote, itemB);
    await controller.loadMore();
    expect(controller.catalogIssue, CatalogIssue.retrying);
    expect(controller.showingSavedCopies, isTrue);
    expect(controller.entries.single.remote, itemB);
    expect(controller.hasMore, isFalse);
  });

  testWidgets(
    'shows a cached server-only item after offline launch without enabling edits',
    (tester) async {
      final item = example(title: 'Server-only saved item');
      shares
        ..mode = UploadMode.live
        ..account = _account(item.userId);
      final catalog = _CatalogAdapter(
        (_, __) async =>
            CatalogSnapshot(items: [item], phase: CatalogPhase.offline),
      );
      await tester.pumpWidget(
        ItdaApp(
          initialLocale: const Locale('en'),
          api: api,
          shareBridge: shares,
          catalogBridge: catalog,
          notificationBridge: _DetailsAdapter(item, offline: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Saved copies'), findsOneWidget);
      await _tapPebble(tester, 'server:${item.id}');
      await tester.pumpAndSettle();
      expect(find.text('Showing the last loaded version.'), findsOneWidget);
      expect(find.byTooltip('Edit'), findsNothing);
      await _expandDetails(tester);
      await _scrollTo(tester, 'Original source');
      expect(find.text(item.sourceUrl!), findsOneWidget);
    },
  );

  test('tombstones hide acknowledged cards without changing pending originals',
      () async {
    final item = example();
    shares
      ..account = _account(item.userId)
      ..items = [
        _local('acknowledged', 'Original copy',
            state: LocalUploadState.synchronized, serverId: item.id),
        _local('pending', 'Pending original'),
      ];
    final catalog = _CatalogAdapter((_, __) async => CatalogSnapshot(
          items: [],
          phase: CatalogPhase.current,
          removed: {item.id},
        ));
    final controller = LibraryController(shares, catalog);
    addTearDown(controller.dispose);
    await controller.reload();
    expect(catalog.lastAcknowledged, {item.id});
    expect(controller.entries.single.local?.label, 'Pending original');
    expect(shares.items, hasLength(2));
  });

  testWidgets(
      'keeps accessible targets and layout at large text in light and dark mode',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    final semantics = tester.ensureSemantics();
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    try {
      shares.items = [
        _local('small-screen', 'A long title for a saved item with wrapping')
      ];
      await tester.pumpWidget(ItdaApp(
          initialLocale: const Locale('en'), api: api, shareBridge: shares));
      await tester.pumpAndSettle();
      final library = find.text('잇다');
      expect(Theme.of(tester.element(library)).brightness, Brightness.light);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(Theme.of(tester.element(library)).brightness, Brightness.dark);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Account'));
      await tester.pumpAndSettle();
      expect(find.text('On this device'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
Future<void> _tapPebble(WidgetTester tester, String id) =>
    tester.tapAt(tester.getCenter(find.byKey(ValueKey('pebble:$id'))));

Future<void> _dropOnArchive(WidgetTester tester, Finder stone) async {
  final drag = await tester.startGesture(tester.getCenter(stone));
  await drag.moveBy(const Offset(0, -55));
  await tester.pump(const Duration(milliseconds: 20));
  await drag.moveTo(tester.getCenter(find.text('Archive')));
  await tester.pump(const Duration(milliseconds: 20));
  await drag.up();
}
Future<void> _scrollTo(WidgetTester tester, String text) async {
  await tester.scrollUntilVisible(find.text(text).hitTestable(), 200,
      scrollable: find.byType(Scrollable).first);
}

Future<void> _expandDetails(WidgetTester tester) async {
  await _scrollTo(tester, 'Show details');
  await tester.tap(find.text('Show details').hitTestable());
  await tester.pumpAndSettle();
}
UploadAccount _account(String id) =>
    UploadAccount(id: id, email: '$id@example.test', realm: 'mock');

LocalShare _local(
  String id,
  String text, {
  InputType type = InputType.text,
  LocalUploadState state = LocalUploadState.pending,
  String? serverId,
  bool canAssign = false,
  String? subject,
  String? linkText,
}) =>
    LocalShare(
      localId: id,
      inputType: type,
      label: text,
      receivedAt: DateTime.utc(2026, 11, 10),
      uploadState: state,
      serverContentId: serverId,
      canAssign: canAssign,
      sourceUrl: type == InputType.url ? text : null,
      subject: subject,
      linkText: linkText,
    );

class _LanguageAdapter implements LanguagePreference {
  Locale selected = const Locale('ko');

  @override
  Future<Locale> read() async => selected;

  @override
  Future<void> write(Locale locale) async => selected = locale;
}
class _ShareAdapter implements ShareBridge {
  final events = StreamController<void>.broadcast();
  List<LocalShare> items = [];
  UploadMode mode = UploadMode.disabled;
  String? stagingApiHost;
  UploadAccount? account;
  UploadAccount? nextAccount;
  Future<void>? signInGate;
  String? signInError;
  (String, String)? assigned;
  final opened = <String>[];

  @override
  Stream<void> get changes => events.stream;

  @override
  Future<LocalInbox> listInbox() async => LocalInbox(
      mode: mode,
      account: account,
      shares: items,
      stagingApiHost: stagingApiHost);

  @override
  Future<LocalSource> readLocalSource(String localId) async {
    opened.add(localId);
    final item = items.singleWhere((item) => item.localId == localId);
    return item.inputType == InputType.url
        ? LocalSource(url: item.sourceUrl, subject: item.subject)
        : LocalSource(text: item.label);
  }

  @override
  Future<void> signIn(String email, String password) async {
    if (signInGate case final gate?) await gate;
    if (signInError case final code?) throw PlatformException(code: code);
    account = nextAccount;
    events.add(null);
  }

  @override
  Future<void> signOut() async {
    account = null;
    events.add(null);
  }

  @override
  Future<void> assignShare(String localId, String accountId) async {
    assigned = (localId, accountId);
  }
}
class _CatalogAdapter implements CatalogBridge {
  _CatalogAdapter(this.load);

  final Future<CatalogSnapshot> Function(AccountScope, int) load;
  Set<String>? lastAcknowledged;
  int syncRequests = 0;

  @override
  Future<CatalogSnapshot> snapshot(
    AccountScope scope, {
    required int limit,
    required Set<String> acknowledged,
  }) {
    lastAcknowledged = acknowledged;
    return load(scope, limit);
  }

  @override
  Future<void> synchronize(AccountScope scope) async {
    syncRequests++;
  }
}
class _DetailsAdapter implements NotificationBridge {
  _DetailsAdapter(this.item, {this.offline = false, this.editedItem});

  final ContentItem item;
  final bool offline;
  final ContentItem? editedItem;
  ContentPatch? patch;

  @override
  Stream<void> get changes => const Stream.empty();

  @override
  Future<RegisteredContent> details(NoticeTarget target) async {
    expect(target.contentId, item.id);
    expect(target.ownerId, item.userId);
    if (offline) throw PlatformException(code: 'network_unavailable');
    return RegisteredContent(item, UploadMode.mock, await status(target));
  }

  @override
  Future<LocalSource?> original(NoticeTarget target) async => null;

  @override
  Future<NoticeStatus> status(NoticeTarget target) async => NoticeStatus(
      dismissed:
          item.notification.visibility == NotificationVisibility.dismissed);

  @override
  Future<NoticeNavigation?> takeNavigation() async => null;

  @override
  Future<RegisteredContent> edit(
      NoticeTarget target, ContentPatch patch) async {
    this.patch = patch;
    return RegisteredContent(
        editedItem!, UploadMode.mock, await status(target));
  }

  @override
  Future<void> restore(NoticeTarget target) => throw UnimplementedError();

  @override
  Future<void> refresh() async {}

  @override
  Future<void> enable() async {}
}
class _WorkflowAdapter extends _DetailsAdapter {
  _WorkflowAdapter(this.record) : super(ContentItem.fromJson(record));

  final Map<String, dynamic> record;
  Future<void>? editGate;

  String? editError;
  int edits = 0;

  @override
  ContentItem get item => ContentItem.fromJson(record);

  void advanceVersion() => record['version'] = item.version + 1;

  @override
  Future<RegisteredContent> edit(
    NoticeTarget target,
    ContentPatch patch,
  ) async {
    this.patch = patch;
    edits++;
    if (editGate case final gate?) await gate;
    if (editError case final code?) throw PlatformException(code: code);
    if (patch.expectedVersion != item.version) {
      throw PlatformException(code: 'version_conflict');
    }
    advanceVersion();
    record['workflow_status'] = patch.workflowStatus!.name;
    return details(target);
  }
}
