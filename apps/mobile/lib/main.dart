import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'api/content_api.dart';
import 'api/fixture_content_api.dart';
import 'models/content.dart';
import 'native/notification_bridge.dart';
import 'native/share_bridge.dart';
import 'native/upload_account_dialog.dart';
import 'widgets/content_details.dart';
import 'widgets/registered_content_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const mode =
      String.fromEnvironment('ITDA_DATA_MODE', defaultValue: 'fixture');
  if (mode != 'fixture') {
    throw UnsupportedError('The catalog currently uses fixture mode.');
  }
  final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  runApp(ItdaApp(
    api: await FixtureContentApi.load(),
    shareBridge: android ? const AndroidShareBridge() : null,
    notificationBridge: android ? const AndroidNotificationBridge() : null,
  ));
}

class ItdaApp extends StatefulWidget {
  const ItdaApp(
      {super.key,
      required this.api,
      this.shareBridge,
      this.notificationBridge});
  final ContentApi api;
  final ShareBridge? shareBridge;
  final NotificationBridge? notificationBridge;

  @override
  State<ItdaApp> createState() => _ItdaAppState();
}

class _ItdaAppState extends State<ItdaApp> {
  final _navigator = GlobalKey<NavigatorState>();
  StreamSubscription<void>? _noticeChanges;

  @override
  void initState() {
    super.initState();
    final bridge = widget.notificationBridge;
    if (bridge == null) return;
    _noticeChanges = bridge.changes.listen(
      (_) => unawaited(_openNotification(bridge)),
      onError: (Object _) {},
    );
    WidgetsBinding.instance
        .addPostFrameCallback((_) => unawaited(_openNotification(bridge)));
  }

  @override
  void dispose() {
    unawaited(_noticeChanges?.cancel());
    super.dispose();
  }

  Future<void> _openNotification(NotificationBridge bridge) async {
    final navigator = _navigator.currentState;
    if (navigator == null) return;
    try {
      final navigation = await bridge.takeNavigation();
      if (navigation == null || !navigator.mounted) return;
      unawaited(navigator.push<void>(MaterialPageRoute(
        builder: (_) => RegisteredContentScreen(
          bridge: bridge,
          target: navigation.target,
          openEditor: navigation.destination == NoticeDestination.edit,
        ),
      )));
    } on PlatformException {
      // The library remains usable if native navigation could not be verified.
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        navigatorKey: _navigator,
        title: 'ITDA',
        theme: ThemeData(
            colorSchemeSeed: const Color(0xff225c47), useMaterial3: true),
        home: LibraryScreen(
          api: widget.api,
          shareBridge: widget.shareBridge,
          notificationBridge: widget.notificationBridge,
        ),
        onGenerateRoute: (settings) {
          final uri = Uri.tryParse(settings.name ?? '');
          if (uri != null &&
              uri.pathSegments.length == 2 &&
              uri.pathSegments.first == 'contents') {
            return MaterialPageRoute<void>(
                builder: (_) =>
                    DetailScreen(api: widget.api, id: uri.pathSegments[1]));
          }
          return MaterialPageRoute<void>(
              builder: (_) => const Scaffold(
                  body: Center(child: Text('Content not found'))));
        },
      );
}

const fixtureNotice = 'Sample library · synthetic fixtures';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen(
      {super.key,
      required this.api,
      this.shareBridge,
      this.notificationBridge});
  final ContentApi api;
  final ShareBridge? shareBridge;
  final NotificationBridge? notificationBridge;
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late final Future<ContentPage> _contents = widget.api.listContents();
  Future<LocalInbox>? _inbox;
  AppLifecycleListener? _lifecycle;
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    final bridge = widget.shareBridge;
    if (bridge != null) {
      _inbox = bridge.listInbox();
      _lifecycle = AppLifecycleListener(onResume: _refreshInbox);
      _changes =
          bridge.changes.listen((_) => _refreshInbox(), onError: (Object _) {});
    }
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    unawaited(_changes?.cancel());
    super.dispose();
  }

  void _refreshInbox() {
    final inbox = widget.shareBridge!.listInbox();
    setState(() {
      _inbox = inbox;
    });
  }

  Future<void> _manageAccount(LocalInbox inbox) async {
    await showDialog<void>(
      context: context,
      builder: (_) =>
          UploadAccountDialog(bridge: widget.shareBridge!, inbox: inbox),
    );
    if (mounted) _refreshInbox();
  }

  Future<void> _assign(LocalShare share, UploadAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Upload this share?'),
        content: Text('This share will be assigned to ${account.email}.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Assign and upload'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.shareBridge!.assignShare(share.localId, account.id);
    } on PlatformException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('Could not assign this share. Check the upload account.')),
      );
    }
    if (mounted) _refreshInbox();
  }

  Future<void> _noticeControl(Future<void> Function() action) async {
    try {
      await action();
    } on PlatformException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Notification settings could not be updated.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('ITDA · Saved content')),
        body: CustomScrollView(
          slivers: [
            if (_inbox != null)
              FutureBuilder<LocalInbox>(
                future: _inbox,
                builder: (context, snapshot) {
                  final inbox = snapshot.data;
                  final shares = inbox?.shares ?? const <LocalShare>[];
                  final account = inbox?.account;
                  final notifications = widget.notificationBridge;
                  final status = switch (snapshot) {
                    AsyncSnapshot(hasError: true) =>
                      'Unable to load local shares.',
                    _ when account != null && inbox?.mode == UploadMode.mock =>
                      'Mock uploads · ${account.email}',
                    _ when account != null => 'Uploads to ${account.email}',
                    _ when inbox?.mode == UploadMode.mock =>
                      'Mock upload server',
                    _
                        when snapshot.connectionState ==
                            ConnectionState.waiting =>
                      null,
                    _ when shares.isEmpty =>
                      'Share from another app to save here.',
                    _ when inbox?.mode == UploadMode.disabled =>
                      'Upload setup required.',
                    _ => 'Sign in to upload saved shares.',
                  };
                  return SliverList.builder(
                    itemCount: shares.length + 1,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ListTile(
                              title: const Text('Saved on this device'),
                              subtitle: status == null ? null : Text(status),
                              trailing: inbox != null &&
                                      inbox.mode != UploadMode.disabled
                                  ? TextButton(
                                      onPressed: () => _manageAccount(inbox),
                                      child: Text(account == null
                                          ? 'Sign in'
                                          : 'Account'),
                                    )
                                  : null,
                            ),
                            if (notifications != null && account != null)
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 16),
                                child: Wrap(
                                  spacing: 8,
                                  children: [
                                    if (!inbox!.notificationsEnabled)
                                      TextButton(
                                        onPressed: () => _noticeControl(
                                            notifications.enable),
                                        child:
                                            const Text('Enable notifications'),
                                      ),
                                    TextButton(
                                      onPressed: () =>
                                          _noticeControl(notifications.refresh),
                                      child: const Text('Refresh analysis'),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        );
                      }
                      final share = shares[index - 1];
                      final serverId = share.serverContentId;
                      final realm = account?.realm;
                      final target =
                          account == null || realm == null || serverId == null
                              ? null
                              : NoticeTarget(account.id, realm, serverId);
                      final type = switch (share.inputType) {
                        InputType.text => 'Text',
                        InputType.url => 'Link',
                        InputType.image => 'Image',
                        InputType.document => 'PDF',
                        null => null,
                      };
                      final state = switch (share.uploadState) {
                        LocalUploadState.pending => 'Pending upload',
                        LocalUploadState.uploading => 'Uploading',
                        LocalUploadState.retryWaiting => 'Waiting to retry',
                        LocalUploadState.authenticationRequired =>
                          'Authentication required',
                        LocalUploadState.synchronized =>
                          inbox?.mode == UploadMode.mock
                              ? 'Synchronized (mock)'
                              : 'Synchronized',
                        LocalUploadState.permanentFailure =>
                          share.lastError == 'backend_not_implemented'
                              ? 'Upload failed · server support unavailable'
                              : 'Upload failed',
                      };
                      return ListTile(
                        key: ValueKey(share.localId),
                        title: Text(share.label,
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(type == null ? state : '$type · $state'),
                        onTap: target == null || notifications == null
                            ? null
                            : () => Navigator.of(context)
                                    .push<void>(MaterialPageRoute(
                                  builder: (_) => RegisteredContentScreen(
                                      bridge: notifications, target: target),
                                )),
                        trailing: share.canAssign && account != null
                            ? TextButton(
                                onPressed: () => _assign(share, account),
                                child: const Text('Upload'),
                              )
                            : target != null && notifications != null
                                ? const Icon(Icons.chevron_right)
                                : null,
                      );
                    },
                  );
                },
              ),
            const SliverToBoxAdapter(
              child: Padding(
                  padding: EdgeInsets.all(16), child: Text(fixtureNotice)),
            ),
            FutureBuilder<ContentPage>(
              future: _contents,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return SliverToBoxAdapter(
                    child: Center(
                      child: snapshot.hasError
                          ? const Text('Unable to load fixture content.')
                          : const CircularProgressIndicator(),
                    ),
                  );
                }
                return SliverList.builder(
                  itemCount: snapshot.data!.items.length,
                  itemBuilder: (context, index) {
                    final content = snapshot.data!.items[index];
                    return ListTile(
                      title: Text(content.title ?? 'Untitled content'),
                      subtitle: Text(
                          'Analysis: ${content.analysisStatus.name} · Workflow: ${content.workflowStatus.name}'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context)
                          .pushNamed('/contents/${content.id}'),
                    );
                  },
                );
              },
            ),
          ],
        ),
      );
}

class DetailScreen extends StatefulWidget {
  const DetailScreen({super.key, required this.api, required this.id});
  final ContentApi api;
  final String id;
  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  late final Future<ContentItem> _content = widget.api.getContent(widget.id);
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Content details')),
        body: FutureBuilder<ContentItem>(
            future: _content,
            builder: (context, snapshot) {
              if (snapshot.hasError)
                return const Center(
                    child: Text('Content could not be loaded.'));
              if (!snapshot.hasData)
                return const Center(child: CircularProgressIndicator());
              final content = snapshot.data!;
              return ContentDetails(
                content: content,
                footer: [
                  Text('Notification: ${content.notification.visibility.name}'),
                  const Text(
                      'Dismissing a notification keeps the content and workflow state.'),
                  const SizedBox(height: 16),
                  const FilledButton(
                      onPressed: null, child: Text('Edit (planned)')),
                ],
              );
            }),
      );
}
