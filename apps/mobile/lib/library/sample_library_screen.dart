import 'package:flutter/material.dart';

import '../api/content_api.dart';
import '../l10n/generated/app_localizations.dart';
import '../models/content.dart';
import '../native/share_bridge.dart';
import '../widgets/content_details.dart';
import '../widgets/library_components.dart';
import '../widgets/saved_content_card.dart';
import 'library_controller.dart';

class SampleLibraryScreen extends StatefulWidget {
  const SampleLibraryScreen({super.key, required this.api});

  final ContentApi api;

  @override
  State<SampleLibraryScreen> createState() => _SampleLibraryScreenState();
}

class _SampleLibraryScreenState extends State<SampleLibraryScreen> {
  late Future<ContentPage> _page = widget.api.listContents();

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(copy.sampleLibrary)),
      body: FutureBuilder<ContentPage>(
        future: _page,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return PageList(children: [
              StatePanel(
                icon: Icons.info_outline,
                title: copy.loadLibraryError,
                action: () => setState(() => _page = widget.api.listContents()),
                actionLabel: copy.retry,
              ),
            ]);
          }
          final page = snapshot.data;
          if (page == null)
            return Center(
                child: CircularProgressIndicator(
                    semanticsLabel: copy.loadingLibrary));
          return PageList(
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(copy.sampleIntro,
                    style: Theme.of(context).textTheme.bodyLarge),
              ),
              for (final item in page.items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: SavedContentCard(
                    entry: LibraryEntry(item.id, remote: item),
                    mode: UploadMode.disabled,
                    sample: true,
                    onOpen: () =>
                        Navigator.of(context).push<void>(MaterialPageRoute(
                      builder: (_) => Scaffold(
                        appBar: AppBar(title: Text(copy.detailsTitle)),
                        body: ContentDetails(
                            content: item, badge: copy.sampleLabel),
                      ),
                    )),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
