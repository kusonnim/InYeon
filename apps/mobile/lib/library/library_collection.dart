import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../native/share_bridge.dart';
import '../widgets/itda_theme.dart';
import '../widgets/library_components.dart';
import '../widgets/saved_content_row.dart';
import 'library_controller.dart';

class LibraryCollection extends StatelessWidget {
  const LibraryCollection({
    super.key,
    required this.controller,
    required this.archived,
    required this.refresh,
    required this.openEntry,
  });

  final LibraryController controller;
  final bool archived;
  final Future<void> Function() refresh;
  final VoidCallback? Function(BuildContext, LibraryEntry, UploadMode)
  openEntry;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => _CollectionView(
      key: ValueKey((controller.scope, archived)),
      collection: this,
    ),
  );
}
class _CollectionView extends StatefulWidget {
  const _CollectionView({super.key, required this.collection});

  final LibraryCollection collection;

  @override
  State<_CollectionView> createState() => _CollectionViewState();
}
class _CollectionViewState extends State<_CollectionView> {
  bool _searching = false;
  String _query = '';

  void _toggleSearch() => setState(() {
    _searching = !_searching;
    _query = '';
  });

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final collection = widget.collection;
    final controller = collection.controller;
    final archived = collection.archived;
    final mode = controller.inbox?.mode ?? UploadMode.disabled;
    final groups = <Object, List<LibraryEntry>>{};
    for (final entry in controller.entries.where(
      (entry) => entry.archived == archived,
    )) {
      final url = archived ? null : entry.linkUrl;
      groups.putIfAbsent(url ?? (entry.key,), () => []).add(entry);
    }
    final rows = groups.values
        .where(
          (row) => row.any(
            (entry) =>
                entryTitle(copy, entry).toLowerCase().contains(_query) ||
                sourceCue(
                  copy,
                  entry.type,
                  entry.linkUrl,
                ).toLowerCase().contains(_query),
          ),
        )
        .toList(growable: false);
    final showEmpty =
        rows.isEmpty &&
        (!controller.hasMore || _query.isNotEmpty) &&
        !controller.loadingCatalog &&
        controller.inbox != null &&
        controller.catalogIssue == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(archived ? copy.archiveTitle : copy.allSaved),
        actions: [
          IconButton(
            tooltip: _searching ? copy.closeSearch : copy.searchSaved,
            onPressed: _toggleSearch,
            icon: Icon(_searching ? Icons.close : Icons.search),
          ),
          IconButton(
            tooltip: copy.refreshLibrary,
            onPressed: collection.refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: PageWidth(
        child: Column(
          children: [
            if (_searching)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  ItdaSpace.page,
                  ItdaSpace.small,
                  ItdaSpace.page,
                  ItdaSpace.small,
                ),
                child: TextField(
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(labelText: copy.searchSaved),
                  onChanged: (value) =>
                      setState(() => _query = value.trim().toLowerCase()),
                ),
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: collection.refresh,
                child: CustomScrollView(
                  key: PageStorageKey((controller.scope, archived)),
                  physics: const AlwaysScrollableScrollPhysics(),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: ItdaSpace.page,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: LibraryStatus(
                          controller: controller,
                          refresh: collection.refresh,
                        ),
                      ),
                    ),
                    if (showEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(ItdaSpace.page),
                          child: Text(
                            _query.isEmpty
                                ? (archived
                                      ? copy.archiveEmpty
                                      : copy.emptyLibrary)
                                : (controller.hasMore
                                      ? copy.noLoadedMatches
                                      : copy.noMatches),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: ItdaSpace.page,
                      ),
                      sliver: SliverList.builder(
                        itemCount: rows.length,
                        itemBuilder: (context, index) =>
                            _row(context, rows[index], mode),
                      ),
                    ),
                    if (controller.hasMore)
                      SliverToBoxAdapter(
                        child: Center(
                          child: TextButton(
                            onPressed: controller.loadMore,
                            child: Text(copy.loadMore),
                          ),
                        ),
                      ),
                    const SliverToBoxAdapter(
                      child: SizedBox(height: ItdaSpace.large),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, List<LibraryEntry> row, UploadMode mode) {
    final copy = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final first = row.first;
    Widget tile(LibraryEntry entry) {
      final local = entry.local;
      return SavedContentRow(
        key: ValueKey(entry.key),
        entry: entry,
        onOpen: widget.collection.openEntry(context, entry, mode),
        showSavedAt: row.length > 1,
        status:
            mode != UploadMode.disabled &&
                local?.inputType != null &&
                local!.uploadState != LocalUploadState.synchronized
            ? uploadName(copy, mode, local)
            : null,
      );
    }

    if (row.length == 1) return tile(first);
    return ExpansionTile(
      key: PageStorageKey((widget.collection.controller.scope, first.linkUrl)),
      shape: const Border(),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsetsDirectional.only(
        start: ItdaSpace.section,
      ),
      leading: Icon(
        sourceIcon(first.type),
        size: 20,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(
        entryTitle(copy, first),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleMedium,
      ),
      subtitle: Wrap(
        spacing: ItdaSpace.small,
        children: [
          Text(
            sourceCue(copy, first.type, first.linkUrl),
            style: theme.textTheme.bodySmall,
          ),
          Text(
            copy.repeatedLinkCount(row.length),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
      children: [for (final entry in row) tile(entry)],
    );
  }
}
class LibraryStatus extends StatelessWidget {
  const LibraryStatus({
    super.key,
    required this.controller,
    required this.refresh,
  });

  final LibraryController controller;
  final VoidCallback refresh;

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final inbox = controller.inbox;
    final mode = inbox?.mode ?? UploadMode.disabled;
    final issue = controller.catalogIssue;
    final environment = uploadEnvironmentLabel(copy, mode);
    final saved = controller.showingSavedCopies;
    final problem = controller.localError
        ? copy.localLoadError
        : switch (issue) {
            CatalogIssue.connection => copy.offlineTitle,
            CatalogIssue.unavailable => copy.loadLibraryError,
            CatalogIssue.retrying => copy.syncDelayed,
            null => null,
          };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (environment != null || saved)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: ItdaSpace.small),
            child: Wrap(
              spacing: ItdaSpace.medium,
              children: [
                if (environment != null)
                  Text(environment, style: theme.textTheme.bodySmall),
                if (saved)
                  Text(copy.savedCopies, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        if (problem != null)
          Row(
            children: [
              Expanded(child: Text(problem)),
              TextButton(onPressed: refresh, child: Text(copy.retry)),
            ],
          )
        else if (inbox == null || controller.loadingCatalog)
          LinearProgressIndicator(semanticsLabel: copy.syncingLibrary),
      ],
    );
  }
}
