import 'package:flutter/material.dart';
import 'api/content_api.dart';
import 'api/fixture_content_api.dart';
import 'models/content.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const mode = String.fromEnvironment('ITDA_DATA_MODE', defaultValue: 'fixture');
  if (mode != 'fixture') {
    throw UnsupportedError('Real API mode requires authenticated session wiring. Phase 0 supports fixture mode.');
  }
  runApp(ItdaApp(api: await FixtureContentApi.load()));
}

class ItdaApp extends StatelessWidget {
  const ItdaApp({super.key, required this.api});
  final ContentApi api;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ITDA',
    theme: ThemeData(colorSchemeSeed: const Color(0xff225c47), useMaterial3: true),
    home: LibraryScreen(api: api),
    onGenerateRoute: (settings) {
      final uri = Uri.tryParse(settings.name ?? '');
      if (uri != null && uri.pathSegments.length == 2 && uri.pathSegments.first == 'contents') {
        return MaterialPageRoute<void>(builder: (_) => DetailScreen(api: api, id: uri.pathSegments[1]));
      }
      return MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Center(child: Text('Content not found'))));
    },
  );
}

const fixtureNotice = 'Phase 0 synthetic fixtures. Sharing, notifications, sign-in and synchronization are planned.';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.api});
  final ContentApi api;
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}
class _LibraryScreenState extends State<LibraryScreen> {
  late final Future<ContentPage> _contents = widget.api.listContents();
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('ITDA · Saved content')),
    body: Column(children: [
      const Padding(padding: EdgeInsets.all(16), child: Text(fixtureNotice)),
      Expanded(child: FutureBuilder<ContentPage>(future: _contents, builder: (context, snapshot) {
        if (snapshot.hasError) return const Center(child: Text('Unable to load fixture content.'));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        return ListView.builder(
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
      })),
    ]),
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
        ...?content.analysis?.limitations.map((text) => Text(text)),
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
