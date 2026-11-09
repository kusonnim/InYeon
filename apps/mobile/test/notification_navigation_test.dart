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
    await tester.pump();
    await _showControl(tester, 'Save changes');
    await tester.tap(find.text('Save changes').hitTestable());
    await tester.pumpAndSettle();
    expect(adapter.patch!.expectedVersion, adapter.content.version);
    expect(adapter.patch!.title, 'Synthetic title');
    expect(adapter.patch!.workflowStatus, isNull);
    expect(find.text('Saved to mock server.'), findsOneWidget);
    expect(find.text('Content details'), findsOneWidget);
  });

  testWidgets(
      'a conflict keeps the draft and preserves an untouched server note',
      (tester) async {
    adapter.navigation =
        NoticeNavigation(adapter.target, NoticeDestination.edit);
    adapter.editError = PlatformException(code: 'version_conflict');
    final originalVersion = adapter.content.version;
    await tester.pumpWidget(ItdaApp(api: api, notificationBridge: adapter));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'My title draft');
    await tester.pump();
    await _showControl(tester, 'Save changes');
    await tester.tap(find.text('Save changes').hitTestable());
    await tester.pumpAndSettle();
    expect(adapter.patch!.expectedVersion, originalVersion);

    final catalog =
        jsonDecode(File('assets/fixtures/catalog.json').readAsStringSync())
            as Map<String, dynamic>;
    adapter.content = ContentItem.fromJson({
      ...(catalog['items'] as List).first as Map<String, dynamic>,
      'title': 'New title from the server',
      'user_note': 'A newer server note',
      'version': originalVersion + 1,
    });
    adapter.editError = null;
    await _showControl(tester, 'Load latest version', delta: -180);
    await tester.tap(find.text('Load latest version').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('Latest saved values'), findsOneWidget);
    expect(find.text('New title from the server'), findsOneWidget);
    await _showControl(tester, 'Save changes');
    final fields =
        tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields.first.controller!.text, 'My title draft');
    expect(fields.last.controller!.text, 'A newer server note');
    await tester.tap(find.text('Save changes').hitTestable());
    await tester.pumpAndSettle();
    expect(adapter.patch!.toJson(), {
      'expected_version': originalVersion + 1,
      'title': 'My title draft',
    });
    expect(find.text('Content details'), findsOneWidget);
  });

  testWidgets(
      'returning from a notification editor confirms discarding a draft',
      (tester) async {
    adapter.navigation =
        NoticeNavigation(adapter.target, NoticeDestination.edit);
    await tester.pumpWidget(ItdaApp(api: api, notificationBridge: adapter));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextField).first, 'Uncommitted note title');
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Discard your draft?'), findsOneWidget);
    await tester.tap(find.text('Discard draft'));
    await tester.pumpAndSettle();
    expect(find.text('Content details'), findsOneWidget);
    expect(adapter.patch, isNull);
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

Future<void> _showControl(WidgetTester tester, String label,
    {double delta = 180}) async {
  final control = find.text(label).hitTestable();
  if (control.evaluate().isNotEmpty) return;
  await tester.scrollUntilVisible(control, delta,
      scrollable: find.byType(Scrollable).first);
}

class _NotificationAdapter implements NotificationBridge {
  _NotificationAdapter(this.content);

  ContentItem content;
  late final target = NoticeTarget(content.userId, 'mock-realm', content.id);
  final events = StreamController<void>.broadcast();
  final opened = <NoticeTarget>[];
  NoticeNavigation? navigation;
  NoticeStatus notice = const NoticeStatus();
  ContentPatch? patch;
  PlatformException? editError;
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
    if (editError case final error?) throw error;
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
