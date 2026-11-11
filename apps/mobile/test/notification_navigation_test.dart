import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itda_mobile/api/fixture_content_api.dart';
import 'package:itda_mobile/main.dart';
import 'package:itda_mobile/models/content.dart';
import 'package:itda_mobile/native/notification_bridge.dart';
import 'package:itda_mobile/native/share_bridge.dart';
import 'package:itda_mobile/widgets/original_image.dart';

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

  testWidgets('opens the scoped details from a cold notification tap', (
    tester,
  ) async {
    adapter.navigation = NoticeNavigation(
      adapter.target,
      NoticeDestination.details,
    );
    await tester.pumpWidget(
      ItdaApp(
        initialLocale: const Locale('en'),
        api: api,
        notificationBridge: adapter,
      ),
    );
    await tester.pumpAndSettle();
    expect(adapter.opened, [adapter.target]);
    expect(find.text('Content details'), findsOneWidget);
    expect(find.text('Open original'), findsNothing);
    await _expandDetails(tester);
    expect(find.text('Mock content'), findsOneWidget);
    expect(find.text('Open original'), findsOneWidget);
  });

  testWidgets(
      'a warm edit action opens the editor and saves an explicit versioned patch',
      (tester) async {
    await tester.pumpWidget(ItdaApp(
        initialLocale: const Locale('en'),
        api: api,
        notificationBridge: adapter));
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

  testWidgets('pre-fills stored edits and offers the original separately',
      (tester) async {
    final item = _catalogItem({
      'title': 'A title I saved',
      'user_note': 'Bring the registration form.',
    });
    adapter.content = item;
    adapter.navigation =
        NoticeNavigation(adapter.target, NoticeDestination.edit);
    await tester.pumpWidget(ItdaApp(
        initialLocale: const Locale('en'),
        api: api,
        notificationBridge: adapter));
    await tester.pumpAndSettle();
    final fields =
        tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields.first.controller!.text, item.title);
    expect(fields.last.controller!.text, item.userNote);
    await _showControl(tester, 'Original source');
    expect(find.text(item.sourceUrl!), findsOneWidget);
    await _showControl(tester, 'Open original');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Content details'), findsOneWidget);
    expect(adapter.patch, isNull);
  });

  testWidgets('a source-derived title hint does not become a field edit', (
    tester,
  ) async {
    final item = _catalogItem({'title': null, 'user_note': null});
    adapter.content = item;
    adapter.localSource = const LocalSource(subject: 'Original shared title');
    adapter.navigation = NoticeNavigation(
      adapter.target,
      NoticeDestination.details,
    );
    await tester.pumpWidget(
      ItdaApp(
        initialLocale: const Locale('en'),
        api: api,
        notificationBridge: adapter,
      ),
    );
    await tester.pumpAndSettle();
    await _expandDetails(tester);
    await _showControl(tester, 'Edit notes');
    await tester.tap(find.text('Edit notes').hitTestable());
    await tester.pumpAndSettle();
    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(fields.first.decoration!.hintText, 'Original shared title');
    expect(fields.first.controller!.text, isEmpty);
    expect(fields.last.controller!.text, isEmpty);
    expect(fields.last.focusNode!.hasFocus, isTrue);
    await _showControl(tester, 'Save changes');
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Save changes'),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byType(TextField).last, 'My note only.');
    await tester.pump();
    await _showControl(tester, 'Save changes');
    await tester.tap(find.text('Save changes').hitTestable());
    await tester.pumpAndSettle();
    expect(adapter.patch!.toJson(), {
      'expected_version': item.version,
      'user_note': 'My note only.',
    });
  });

  testWidgets(
    'notes tap focuses the saved note and supports discard and clear',
    (tester) async {
      final item = _catalogItem({'user_note': 'A saved note'});
      adapter.content = item;
      adapter.navigation = NoticeNavigation(
        adapter.target,
        NoticeDestination.details,
      );
      await tester.pumpWidget(ItdaApp(api: api, notificationBridge: adapter));
      await tester.pumpAndSettle();
      await _expandDetails(tester, '상세히 보기');
      await _showControl(tester, 'A saved note');
      expect(find.byTooltip('메모 수정'), findsOneWidget);
      await tester.tap(find.text('A saved note').hitTestable());
      await tester.pumpAndSettle();
      final notes = find.byType(TextField).last;
      expect(tester.widget<TextField>(notes).focusNode!.hasFocus, isTrue);
      expect(tester.widget<TextField>(notes).controller!.text, item.userNote);
      await tester.enterText(notes, 'Discard this draft');
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('작성 내용 지우기'));
      await tester.pumpAndSettle();
      expect(adapter.patch, isNull);

      await _expandDetails(tester, '상세히 보기');
      await _showControl(tester, 'A saved note');
      await tester.tap(find.text('A saved note').hitTestable());
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(notes).controller!.text, item.userNote);
      await tester.enterText(notes, '');
      await tester.pumpAndSettle();
      adapter.content = _catalogItem({
        'user_note': null,
        'version': item.version + 1,
      });
      await _showControl(tester, '변경 사항 저장');
      await tester.tap(find.text('변경 사항 저장').hitTestable());
      await tester.pumpAndSettle();
      expect(adapter.patch!.toJson(), {
        'expected_version': item.version,
        'user_note': null,
      });
      await _expandDetails(tester, '상세히 보기');
      await _showControl(tester, '메모 수정');
      expect(find.text('메모 수정'), findsOneWidget);
    },
  );

  testWidgets(
      'a sync update and conflict keep the draft and preserve a server note',
      (tester) async {
    adapter.navigation =
        NoticeNavigation(adapter.target, NoticeDestination.details);
    adapter.editError = PlatformException(code: 'version_conflict');
    final originalVersion = adapter.content.version;
    await tester.pumpWidget(ItdaApp(
        initialLocale: const Locale('en'),
        api: api,
        notificationBridge: adapter));
    await tester.pumpAndSettle();
    await tester.tap(find.text(adapter.content.title!));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'My title draft');
    await tester.pump();

    final catalog =
        jsonDecode(File('assets/fixtures/catalog.json').readAsStringSync())
            as Map<String, dynamic>;
    adapter.content = ContentItem.fromJson({
      ...(catalog['items'] as List).first as Map<String, dynamic>,
      'title': 'New title from the server',
      'user_note': 'A newer server note',
      'version': originalVersion + 1,
    });
    adapter.events.add(null);
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'My title draft');
    await _showControl(tester, 'Save changes');
    await tester.tap(find.text('Save changes').hitTestable());
    await tester.pumpAndSettle();
    expect(adapter.patch!.expectedVersion, originalVersion);

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
    await tester.pumpWidget(ItdaApp(
        initialLocale: const Locale('en'),
        api: api,
        notificationBridge: adapter));
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
    await tester.pumpWidget(ItdaApp(
        initialLocale: const Locale('en'),
        api: api,
        notificationBridge: adapter));
    await tester.pumpAndSettle();
    await _expandDetails(tester);
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

  testWidgets('hides loaded content when the original account loses access', (
    tester,
  ) async {
    adapter.navigation = NoticeNavigation(
      adapter.target,
      NoticeDestination.details,
    );
    await tester.pumpWidget(
      ItdaApp(
        initialLocale: const Locale('en'),
        api: api,
        notificationBridge: adapter,
      ),
    );
    await tester.pumpAndSettle();
    await _expandDetails(tester);
    expect(find.text('Open original'), findsOneWidget);
    adapter.authorized = false;
    adapter.events.add(null);
    await tester.pumpAndSettle();
    expect(find.text('Open original'), findsNothing);
    expect(
      find.text('Sign in with the account that saved this content.'),
      findsOneWidget,
    );
  });

  testWidgets('opens an offline acknowledged image and zooms it in place',
      (tester) async {
    final folder = Directory.systemTemp.createTempSync('itda-test-image-');
    addTearDown(() => folder.deleteSync(recursive: true));
    final file = File.fromUri(folder.uri.resolve('saved-image.png'));
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const Color(0xff226644), BlendMode.src);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(80, 40);
    await tester.runAsync(() async {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      file.writeAsBytesSync(data!.buffer.asUint8List());
    });
    image.dispose();
    picture.dispose();
    adapter.offline = true;
    adapter.localSource = LocalSource(
      inputType: InputType.image,
      filename: 'saved-image.png',
      imagePath: file.path,
    );
    adapter.navigation =
        NoticeNavigation(adapter.target, NoticeDestination.details);
    final preview = find.descendant(
      of: find.byType(OriginalImage),
      matching: find.byType(InkWell),
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(ItdaApp(
          initialLocale: const Locale('en'),
          api: api,
          notificationBridge: adapter));
      for (var attempt = 0;
          attempt < 20 && preview.evaluate().isEmpty;
          attempt++) {
        await tester.pump(const Duration(milliseconds: 30));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    });
    await tester.pumpAndSettle();
    expect(find.text('Connection unavailable'), findsOneWidget);
    expect(preview, findsOneWidget);
    await tester.tap(preview);
    await tester.pump();
    final viewer = find.byType(InteractiveViewer);
    expect(viewer, findsOneWidget);
    final center = tester.getCenter(viewer);
    final left =
        await tester.startGesture(center - const Offset(40, 0), pointer: 1);
    final right =
        await tester.startGesture(center + const Offset(40, 0), pointer: 2);
    await left.moveBy(const Offset(-55, 0));
    await right.moveBy(const Offset(55, 0));
    await tester.pump();
    final transforms = tester.widgetList<Transform>(
        find.descendant(of: viewer, matching: find.byType(Transform)));
    expect(transforms.any((item) => item.transform.getMaxScaleOnAxis() > 1.1),
        isTrue);
    await left.up();
    await right.up();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(viewer, findsNothing);
    expect(preview, findsOneWidget);
  });

  testWidgets('a server-only image explains why a private preview is absent',
      (tester) async {
    adapter.content = _catalogItem({
      'input_type': 'image',
      'source_url': null,
      'source_text': null,
    });
    adapter.navigation =
        NoticeNavigation(adapter.target, NoticeDestination.details);
    await tester.pumpWidget(ItdaApp(
        initialLocale: const Locale('en'),
        api: api,
        notificationBridge: adapter));
    await tester.pumpAndSettle();
    await _showControl(tester,
        'This image has no copy on this device. Private download is unavailable.');
    expect(find.byType(OriginalImage), findsNothing);
  });
  testWidgets('uses the saved PDF filename and opens the scoped original', (
    tester,
  ) async {
    adapter.content = _catalogItem({
      'input_type': 'document',
      'source_text': null,
      'source_url': null,
      'title': null,
      'analysis': null,
      'analysis_status': 'pending',
      'recommendations': <Object>[],
    });
    adapter.localSource = const LocalSource(
      inputType: InputType.document,
      subject: 'Shared attachment',
      filename: 'Field notes.pdf',
    );
    adapter.navigation = NoticeNavigation(
      adapter.target,
      NoticeDestination.details,
    );
    const channel = MethodChannel('com.itda.itda_mobile/local_shares');
    final messenger = tester.binding.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      throw PlatformException(code: 'document_viewer_unavailable');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      ItdaApp(
        initialLocale: const Locale('en'),
        api: api,
        notificationBridge: adapter,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Field notes.pdf'), findsOneWidget);
    expect(find.text('Shared attachment'), findsNothing);
    expect(find.text('Recommendations'), findsNothing);
    expect(find.text('Open original'), findsNothing);
    await _expandDetails(tester);
    await _showControl(tester, 'Open original');
    await tester.tap(find.text('Open original').hitTestable());
    await tester.pumpAndSettle();
    expect(calls.single.method, 'openSavedDocument');
    expect(calls.single.arguments, adapter.target.toMessage());
    expect(find.text('Install a PDF viewer to open this file.'), findsOneWidget);
  });
}

ContentItem _catalogItem(Map<String, dynamic> changes) {
  final catalog =
      jsonDecode(File('assets/fixtures/catalog.json').readAsStringSync())
          as Map<String, dynamic>;
  return ContentItem.fromJson({
    ...(catalog['items'] as List).first as Map<String, dynamic>,
    ...changes,
  });
}
Future<void> _showControl(WidgetTester tester, String label,
    {double delta = 180}) async {
  final control = find.text(label).hitTestable();
  if (control.evaluate().isNotEmpty) return;
  await tester.scrollUntilVisible(control, delta,
      scrollable: find.byType(Scrollable).first);
}

Future<void> _expandDetails(WidgetTester tester, [String label = 'Show details']) async {
  await _showControl(tester, label);
  await tester.tap(find.text(label).hitTestable());
  await tester.pumpAndSettle();
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
  LocalSource? localSource;
  bool authorized = true;
  bool offline = false;
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
    if (offline) throw PlatformException(code: 'network_unavailable');
    return RegisteredContent(content, UploadMode.mock, notice);
  }

  @override
  Future<LocalSource?> original(NoticeTarget target) async => localSource;

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
