import 'package:flutter/material.dart';

import '../api/content_api.dart';
import '../l10n/generated/app_localizations.dart';
import '../models/content.dart';
import '../widgets/content_details.dart';
import '../widgets/library_components.dart';
import '../widgets/saved_content_row.dart';
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
            return PageList(
              children: [
                StatePanel(
                  icon: Icons.info_outline,
                  title: copy.loadLibraryError,
                  action: () =>
                      setState(() => _page = widget.api.listContents()),
                  actionLabel: copy.retry,
                ),
              ],
            );
          }
          final page = snapshot.data;
          if (page == null)
            return Center(
              child: CircularProgressIndicator(
                semanticsLabel: copy.loadingLibrary,
              ),
            );
          return PageList(
            children: [
              for (final item in page.items)
                SavedContentRow(
                  entry: LibraryEntry(item.id, remote: item),
                  onOpen: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => Scaffold(
                        appBar: AppBar(
                          title: Text(
                            copy.detailsTitle,
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ),
                        body: ContentDetails(
                          content: item,
                          contextLabel: copy.sampleLabel,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
