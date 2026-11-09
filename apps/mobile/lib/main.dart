import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'api/content_api.dart';
import 'api/fixture_content_api.dart';
import 'models/content.dart';
import 'native/share_bridge.dart';
import 'native/upload_account_dialog.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const mode = String.fromEnvironment('ITDA_DATA_MODE', defaultValue: 'fixture');
  if (mode != 'fixture') {
    throw UnsupportedError('The catalog currently uses fixture mode.');
  }
  runApp(ItdaApp(
    api: await FixtureContentApi.load(),
    shareBridge: !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? const AndroidShareBridge()
        : null,
  ));
}

class ItdaApp extends StatelessWidget {
  const ItdaApp({super.key, required this.api, this.shareBridge});
  final ContentApi api;
  final ShareBridge? shareBridge;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ITDA',
    theme: ThemeData(colorSchemeSeed: const Color(0xff225c47), useMaterial3: true),
    home: LibraryScreen(api: api, shareBridge: shareBridge),
    onGenerateRoute: (settings) {
      final uri = Uri.tryParse(settings.name ?? '');
      if (uri != null && uri.pathSegments.length == 2 && uri.pathSegments.first == 'contents') {
        return MaterialPageRoute<void>(builder: (_) => DetailScreen(api: api, id: uri.pathSegments[1]));
      }
      return MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Center(child: Text('Content not found'))));
    },
  );
}

const fixtureNotice = 'Sample library · synthetic fixtures';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.api, this.shareBridge});
  final ContentApi api;
  final ShareBridge? shareBridge;
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
      _changes = bridge.changes.listen((_) => _refreshInbox(), onError: (Object _) {});
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
      builder: (_) => UploadAccountDialog(bridge: widget.shareBridge!, inbox: inbox),
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
        const SnackBar(content: Text('Could not assign this share. Check the upload account.')),
      );
    }
    if (mounted) _refreshInbox();
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
              final status = switch (snapshot) {
                AsyncSnapshot(hasError: true) => 'Unable to load local shares.',
                _ when account != null && inbox?.mode == UploadMode.mock =>
                  'Mock uploads · ${account.email}',
                _ when account != null => 'Uploads to ${account.email}',
                _ when inbox?.mode == UploadMode.mock => 'Mock upload server',
                _ when snapshot.connectionState == ConnectionState.waiting => null,
                _ when shares.isEmpty => 'Share from another app to save here.',
                _ when inbox?.mode == UploadMode.disabled => 'Upload setup required.',
                _ => 'Sign in to upload saved shares.',
              };
              return SliverList.builder(
                itemCount: shares.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return ListTile(
                      title: const Text('Saved on this device'),
                      subtitle: status == null ? null : Text(status),
                      trailing: inbox != null && inbox.mode != UploadMode.disabled
                          ? TextButton(
                              onPressed: () => _manageAccount(inbox),
                              child: Text(account == null ? 'Sign in' : 'Account'),
                            )
                          : null,
                    );
                  }
                  final share = shares[index - 1];
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
                    LocalUploadState.authenticationRequired => 'Authentication required',
                    LocalUploadState.synchronized =>
                      inbox?.mode == UploadMode.mock ? 'Synchronized (mock)' : 'Synchronized',
                    LocalUploadState.permanentFailure =>
                      share.lastError == 'backend_not_implemented'
                          ? 'Upload failed · server support unavailable'
                          : 'Upload failed',
                  };
                  return ListTile(
                    key: ValueKey(share.localId),
                    title: Text(share.label, maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text(type == null ? state : '$type · $state'),
                    trailing: share.canAssign && account != null
                        ? TextButton(
                            onPressed: () => _assign(share, account),
                            child: const Text('Upload'),
                          )
                        : null,
                  );
                },
              );
            },
          ),
        const SliverToBoxAdapter(
          child: Padding(padding: EdgeInsets.all(16), child: Text(fixtureNotice)),
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
                  subtitle: Text('Analysis: ${content.analysisStatus.name} · Workflow: ${content.workflowStatus.name}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).pushNamed('/contents/${content.id}'),
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
    body: FutureBuilder<ContentItem>(future: _content, builder: (context, snapshot) {
      if (snapshot.hasError) return const Center(child: Text('Content could not be loaded.'));
      if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
      final content = snapshot.data!;
      return ListView(padding: const EdgeInsets.all(16), children: [
        Text(content.title ?? 'Untitled content', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 16),
        const Text('Original source', style: TextStyle(fontWeight: FontWeight.bold)),
        if (content.sourceUrl != null) SelectableText(content.sourceUrl!),
        if (content.sourceText != null) Text(content.sourceText!),
        const SizedBox(height: 16),
        const Text('AI interpretation', style: TextStyle(fontWeight: FontWeight.bold)),
        Text(content.analysis?.summary ?? (content.analysis == null ? 'Analysis pending.' : 'No grounded summary is available.')),
        Text('Coverage: ${content.analysis?.coverage.name ?? 'Not analyzed'}'),
        ...?content.analysis?.limitations.map(Text.new),
        const SizedBox(height: 16),
        const Text('Recommendations', style: TextStyle(fontWeight: FontWeight.bold)),
        if (content.recommendations.isEmpty) const Text('No recommendation is appropriate for this content.'),
        ...content.recommendations.map((item) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${item.kind.name}: ${item.text}'),
            if (item.userText != null) Text('User edit: ${item.userText}'),
            Text(item.accepted ? 'Explicitly accepted' : 'Generated suggestion; not accepted'),
          ]),
        )),
        const SizedBox(height: 16),
        const Text('Your notes', style: TextStyle(fontWeight: FontWeight.bold)),
        Text(content.userNote ?? 'No notes yet.'),
        const SizedBox(height: 16),
        Text('Workflow: ${content.workflowStatus.name}'),
        Text('Notification: ${content.notification.visibility.name}'),
        const Text('Dismissing a notification does not complete or delete saved content.'),
        const SizedBox(height: 16),
        const FilledButton(onPressed: null, child: Text('Edit (planned)')),
      ]);
    }),
  );
}
