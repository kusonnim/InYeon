import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itda_mobile/api/fixture_content_api.dart';
import 'package:itda_mobile/main.dart';
import 'package:itda_mobile/models/content.dart';
import 'package:itda_mobile/native/notification_bridge.dart';
import 'package:itda_mobile/native/share_bridge.dart';

void main() {
  late FixtureContentApi api;
  late _NotificationAdapter adapter;

  setUp(() async {
    api = FixtureContentApi(jsonDecode(
      File('assets/fixtures/catalog.json').readAsStringSync(),
    ) as Map<String, dynamic>);
    adapter = _NotificationAdapter((await api.listContents()).items.first);
    addTearDown(adapter.events.close);
  });

  testWidgets('opens the scoped details from a cold notification tap',
      (tester) async {
    adapter.navigation =
        NoticeNavigation(adapter.target, NoticeDestination.details);
    await tester.pumpWidget(ItdaApp(api: api, notificationBridge: adapter));
    await tester.pumpAndSettle();
    expect(adapter.opened, [adapter.target]);
    expect(find.text('Content details'), findsOneWidget);
    expect(find.text('Mock content'), findsOneWidget);
    expect(find.text('Original source'), findsOneWidget);
  });

  testWidgets(
      'a warm edit action opens the editor and saves an explicit versioned patch',
      (tester) async {
    await tester.pumpWidget(ItdaApp(api: api, notificationBridge: adapter));
    await tester.pumpAndSettle();
    adapter.navigation =
        NoticeNavigation(adapter.target, NoticeDestination.edit);
    adapter.events.add(null);
    await tester.pumpAndSettle();
    expect(find.text('Edit content'), findsOneWidget);
    expect(find.text('Mock content'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Synthetic title');
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(adapter.patch!.expectedVersion, adapter.content.version);
    expect(adapter.patch!.title, 'Synthetic title');
    expect(adapter.patch!.workflowStatus, isNull);
    expect(find.text('Saved to mock server.'), findsOneWidget);
    expect(find.text('Content details'), findsOneWidget);
  });

  testWidgets(
      'restores only after the user selects restoration and reports the pending acknowledgment',
      (tester) async {
    adapter.navigation =
        NoticeNavigation(adapter.target, NoticeDestination.details);
    adapter.notice = const NoticeStatus(dismissed: true, canRestore: true);
    await tester.pumpWidget(ItdaApp(api: api, notificationBridge: adapter));
    await tester.pumpAndSettle();
    final restore = find.text('Restore notification');
    await tester.scrollUntilVisible(
      restore.hitTestable(),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(adapter.restoreRequests, 0);
    await tester.tap(restore);
    await tester.pumpAndSettle();
    expect(adapter.restoreRequests, 1);
    expect(find.text('Restoration awaiting server acknowledgment.'),
        findsOneWidget);
    expect(restore, findsNothing);
  });

  testWidgets('hides loaded content when the original account loses access',
      (tester) async {
    adapter.navigation =
        NoticeNavigation(adapter.target, NoticeDestination.details);
    await tester.pumpWidget(ItdaApp(api: api, notificationBridge: adapter));
    await tester.pumpAndSettle();
    expect(find.text('Original source'), findsOneWidget);
    adapter.authorized = false;
    adapter.events.add(null);
    await tester.pumpAndSettle();
    expect(find.text('Original source'), findsNothing);
    expect(find.text('Sign in with the account that saved this content.'),
        findsOneWidget);
  });
}

class _NotificationAdapter implements NotificationBridge {
  _NotificationAdapter(this.content);

  final ContentItem content;
  late final target = NoticeTarget(content.userId, 'mock-realm', content.id);
  final events = StreamController<void>.broadcast();
  final opened = <NoticeTarget>[];
  NoticeNavigation? navigation;
  NoticeStatus notice = const NoticeStatus();
  ContentPatch? patch;
  bool authorized = true;
  int restoreRequests = 0;

  @override
  Stream<void> get changes => events.stream;

  @override
  Future<NoticeNavigation?> takeNavigation() async {
    final next = navigation;
    navigation = null;
    return next;
  }

  @override
  Future<RegisteredContent> details(NoticeTarget target) async {
    opened.add(target);
    return RegisteredContent(content, UploadMode.mock, notice);
  }

  @override
  Future<NoticeStatus> status(NoticeTarget target) async {
    if (!authorized) throw PlatformException(code: 'authentication_required');
    return notice;
  }

  @override
  Future<RegisteredContent> edit(
      NoticeTarget target, ContentPatch patch) async {
    this.patch = patch;
    return RegisteredContent(content, UploadMode.mock, notice);
  }

  @override
  Future<void> restore(NoticeTarget target) async {
    restoreRequests++;
    notice = const NoticeStatus(dismissed: true, pending: 'restore');
  }

  @override
  Future<void> refresh() async {}

  @override
  Future<void> enable() async {}
}
