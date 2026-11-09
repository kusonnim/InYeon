import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'api/content_api.dart';
import 'api/fixture_content_api.dart';
import 'models/content.dart';
import 'native/share_bridge.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const mode = String.fromEnvironment('ITDA_DATA_MODE', defaultValue: 'fixture');
  if (mode != 'fixture') {
    throw UnsupportedError('Real API mode requires authenticated session wiring. Phase 0 supports fixture mode.');
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
  Future<List<PendingShare>>? _pendingShares;
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    final bridge = widget.shareBridge;
    if (bridge != null) {
      _pendingShares = bridge.listPendingShares();
      _lifecycle = AppLifecycleListener(
        onResume: () {
          final shares = bridge.listPendingShares();
          setState(() {
            _pendingShares = shares;
          });
        },
      );
    }
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('ITDA · Saved content')),
    body: CustomScrollView(
      slivers: [
        if (_pendingShares != null)
          FutureBuilder<List<PendingShare>>(
            future: _pendingShares,
            builder: (context, snapshot) {
              final shares = snapshot.data ?? const <PendingShare>[];
              final status = switch (snapshot) {
                AsyncSnapshot(hasError: true) => 'Unable to load local shares.',
                AsyncSnapshot(connectionState: ConnectionState.waiting) => null,
                _ when shares.isEmpty => 'Share from another app to save here.',
                _ => null,
              };
              return SliverList.builder(
                itemCount: shares.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return ListTile(
                      title: const Text('Saved on this device'),
                      subtitle: status == null ? null : Text(status),
                    );
                  }
                  final share = shares[index - 1];
                  final type = switch (share.inputType) {
                    InputType.text => 'Text',
                    InputType.url => 'Link',
                    InputType.image => 'Image',
                    InputType.document => 'PDF',
                  };
                  return ListTile(
                    key: ValueKey(share.localId),
                    title: Text(share.label, maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text('$type · Pending upload'),
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
