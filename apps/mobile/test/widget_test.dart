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
import 'package:itda_mobile/native/notification_bridge.dart';
import 'package:itda_mobile/native/share_bridge.dart';

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

  ContentItem example({String? title, String? owner, bool dismissed = false}) {
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

  testWidgets(
      'shows an empty private library and opens clearly labeled sample details',
      (tester) async {
    final first = example();
    await tester.pumpWidget(ItdaApp(api: api));
    await tester.pumpAndSettle();
    expect(find.text('Nothing saved yet'), findsOneWidget);
    expect(find.text(first.title!), findsNothing);
    await tester.tap(find.text('Explore sample library'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(first.title!));
    await tester.pumpAndSettle();
    expect(find.text('Samples'), findsOneWidget);
    expect(find.text('Original source'), findsOneWidget);
    await _scrollTo(tester, 'AI summary');
    expect(find.text(first.analysis!.summary!), findsOneWidget);
  });

  testWidgets(
      'reads new local shares on resume and opens the saved original offline',
      (tester) async {
    shares.mode = UploadMode.live;
    await tester.pumpWidget(ItdaApp(api: api, shareBridge: shares));
    await tester.pumpAndSettle();
    expect(find.text('Nothing saved yet'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    shares.items = [
      _local('new-item', 'https://example.org/shared', type: InputType.url)
    ];
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.text('example.org'), findsOneWidget);
    expect(find.text('Waiting to sync'), findsOneWidget);
    await tester.tap(find.text('example.org'));
    await tester.pumpAndSettle();
    expect(find.text('Original source'), findsOneWidget);
    expect(find.text('https://example.org/shared'), findsOneWidget);
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
    await tester.pumpWidget(ItdaApp(api: api, shareBridge: shares));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Saved before sign-in'));
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
      'merges a receipt and its dismissed server item into one openable card',
      (tester) async {
    final item = example(dismissed: true);
    shares
      ..mode = UploadMode.mock
      ..account = _account(item.userId)
      ..items = [
        _local('registered', 'Local preview',
            state: LocalUploadState.synchronized, serverId: item.id)
      ];
    final catalog = _CatalogAdapter((_, __) async =>
        CatalogSnapshot(items: [item], phase: CatalogPhase.current));
    await tester.pumpWidget(ItdaApp(
      api: api,
      shareBridge: shares,
      catalogBridge: catalog,
      notificationBridge: _DetailsAdapter(item),
    ));
    await tester.pumpAndSettle();
    expect(find.text('1 saved item'), findsOneWidget);
    expect(find.text(item.title!), findsOneWidget);
    expect(find.text('Local preview'), findsNothing);
    expect(find.text(item.analysis!.summary!), findsOneWidget);
    expect(find.text('Synced'), findsOneWidget);
    await tester.tap(find.text(item.title!));
    await tester.pumpAndSettle();
    expect(find.text('Content details'), findsOneWidget);
    await _scrollTo(tester, 'Notification dismissed');
    expect(find.text('Notification dismissed'), findsOneWidget);
    expect(find.text('Restore notification'), findsNothing);
  });

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
    await tester.pumpWidget(
        ItdaApp(api: api, shareBridge: shares, catalogBridge: catalog));
    await tester.pumpAndSettle();
    expect(find.text('Connection unavailable'), findsOneWidget);
    expect(find.text('A saved note'), findsOneWidget);
    connected = true;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(catalog.syncRequests, 1);
    expect(find.text('Connection unavailable'), findsNothing);
    expect(find.text('2 saved items'), findsOneWidget);
  });

  testWidgets(
      'signing out and signing in replaces the previous account catalog',
      (tester) async {
    final itemA = example(title: 'Account A item', owner: 'a');
    final itemB = example(title: 'Account B item', owner: 'b');
    shares
      ..mode = UploadMode.mock
      ..account = _account('a')
      ..nextAccount = _account('b');
    final catalog = _CatalogAdapter((scope, _) async => CatalogSnapshot(
        items: [scope.ownerId == 'a' ? itemA : itemB],
        phase: CatalogPhase.current));
    await tester.pumpWidget(
        ItdaApp(api: api, shareBridge: shares, catalogBridge: catalog));
    await tester.pumpAndSettle();
    expect(find.text('Account A item'), findsOneWidget);
    await tester.tap(find.byTooltip('Account'));
    await tester.pumpAndSettle();
    expect(find.text('Signed in'), findsOneWidget);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Signed out'), findsOneWidget);
    expect(find.text('a@example.test'), findsNothing);
    await tester.enterText(find.byType(TextFormField).first, 'b@example.test');
    await tester.enterText(find.byType(TextFormField).last, 'synthetic');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('b@example.test'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Account A item'), findsNothing);
    expect(find.text('Account B item'), findsOneWidget);
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
    final catalog = _CatalogAdapter((_, __) async =>
        CatalogSnapshot(items: [item], phase: CatalogPhase.offline));
    await tester.pumpWidget(ItdaApp(
      api: api,
      shareBridge: shares,
      catalogBridge: catalog,
      notificationBridge: _DetailsAdapter(item, offline: true),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Saved copies'), findsOneWidget);
    await _scrollTo(tester, item.title!);
    await tester.tap(find.text(item.title!).hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('Showing the last loaded version.'), findsOneWidget);
    expect(find.byTooltip('Edit'), findsNothing);
    await _scrollTo(tester, 'Original source');
    expect(find.text(item.sourceUrl!), findsOneWidget);
  });

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
      await tester.pumpWidget(ItdaApp(api: api, shareBridge: shares));
      await tester.pumpAndSettle();
      final library = find.text('Library');
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

Future<void> _scrollTo(WidgetTester tester, String text) async {
  await tester.scrollUntilVisible(find.text(text).hitTestable(), 200,
      scrollable: find.byType(Scrollable).first);
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
}) =>
    LocalShare(
      localId: id,
      inputType: type,
      label: text,
      receivedAt: DateTime.utc(2026, 11, 10),
      uploadState: state,
      serverContentId: serverId,
      canAssign: canAssign,
    );

class _ShareAdapter implements ShareBridge {
  final events = StreamController<void>.broadcast();
  List<LocalShare> items = [];
  UploadMode mode = UploadMode.disabled;
  UploadAccount? account;
  UploadAccount? nextAccount;
  (String, String)? assigned;

  @override
  Stream<void> get changes => events.stream;

  @override
  Future<LocalInbox> listInbox() async =>
      LocalInbox(mode: mode, account: account, shares: items);

  @override
  Future<LocalSource> readLocalSource(String localId) async {
    final item = items.singleWhere((item) => item.localId == localId);
    return item.inputType == InputType.url
        ? LocalSource(url: item.label)
        : LocalSource(text: item.label);
  }

  @override
  Future<void> signIn(String email, String password) async {
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
  _DetailsAdapter(this.item, {this.offline = false});

  final ContentItem item;
  final bool offline;

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
  Future<NoticeStatus> status(NoticeTarget target) async => NoticeStatus(
      dismissed:
          item.notification.visibility == NotificationVisibility.dismissed);

  @override
  Future<NoticeNavigation?> takeNavigation() async => null;

  @override
  Future<RegisteredContent> edit(NoticeTarget target, ContentPatch patch) =>
      throw UnimplementedError();

  @override
  Future<void> restore(NoticeTarget target) => throw UnimplementedError();

  @override
  Future<void> refresh() async {}

  @override
  Future<void> enable() async {}
}
