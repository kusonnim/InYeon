import 'dart:async';
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
      LocalShare(
        localId: 'new-local-item',
        inputType: InputType.url,
        label: 'https://example.org/shared',
        receivedAt: DateTime.utc(2026, 11, 9),
        uploadState: LocalUploadState.pending,
      ),
    ];
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.text('https://example.org/shared'), findsOneWidget);
    expect(find.text('Link · Pending upload'), findsOneWidget);
    expect(find.text(fixtureNotice), findsOneWidget);
  });

  testWidgets('assigns a legacy share only after confirming the upload account',
      (tester) async {
    final api = FixtureContentApi(jsonDecode(
      File('assets/fixtures/catalog.json').readAsStringSync(),
    ) as Map<String, dynamic>);
    final bridge = _TestShareBridge()
      ..mode = UploadMode.mock
      ..account = const UploadAccount(id: 'account-a', email: 'a@example.org')
      ..items = [
        LocalShare(
          localId: 'legacy-id',
          inputType: InputType.text,
          label: 'Saved before sign-in',
          receivedAt: DateTime.utc(2026, 11, 9),
          uploadState: LocalUploadState.authenticationRequired,
          canAssign: true,
        ),
      ];
    await tester.pumpWidget(ItdaApp(api: api, shareBridge: bridge));
    await tester.pumpAndSettle();
    expect(bridge.assigned, isNull);
    await tester.tap(find.text('Upload'));
    await tester.pumpAndSettle();
    expect(find.text('This share will be assigned to a@example.org.'),
        findsOneWidget);
    expect(bridge.assigned, isNull);
    await tester.tap(find.text('Assign and upload'));
    await tester.pumpAndSettle();
    expect(bridge.assigned, ('legacy-id', 'account-a'));
  });
}

class _TestShareBridge implements ShareBridge {
  List<LocalShare> items = [];
  UploadMode mode = UploadMode.disabled;
  UploadAccount? account;
  (String, String)? assigned;

  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  Future<LocalInbox> listInbox() async =>
      LocalInbox(mode: mode, account: account, shares: items);

  @override
  Future<void> signIn(String email, String password) async {}

  @override
  Future<void> signOut() async {}

  @override
  Future<void> assignShare(String localId, String accountId) async {
    assigned = (localId, accountId);
  }
}
