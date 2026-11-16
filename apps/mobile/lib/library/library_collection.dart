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
    this.openArchive,
    this.searchFocus,
  });

  final LibraryController controller;
  final bool archived;
  final Future<void> Function() refresh;
  final VoidCallback? Function(BuildContext, LibraryEntry, UploadMode)
  openEntry;
  final VoidCallback? openArchive;
  final FocusNode? searchFocus;

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
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final collection = widget.collection;
    final controller = collection.controller;
    final archived = collection.archived;
    final mode = controller.inbox?.mode ?? UploadMode.disabled;
    final query = _search.text.trim().toLowerCase();
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
                entryTitle(copy, entry).toLowerCase().contains(query) ||
                sourceCue(
                  copy,
                  entry.type,
                  entry.linkUrl,
                ).toLowerCase().contains(query),
          ),
        )
        .toList(growable: false);
    final showEmpty =
        rows.isEmpty &&
        (!controller.hasMore || query.isNotEmpty) &&
        !controller.loadingCatalog &&
        controller.inbox != null &&
        controller.catalogIssue == null;
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        titleSpacing: archived ? ItdaSpace.small : ItdaSpace.page,
        toolbarHeight: itdaToolbarHeight(context),
        title: Text(
          archived ? copy.archiveTitle : copy.allSaved,
          style: archived ? theme.textTheme.titleMedium : null,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (collection.openArchive case final openArchive?)
            IconButton(
              tooltip: copy.archiveTitle,
              onPressed: openArchive,
              icon: const Icon(Icons.archive_outlined),
            ),
          IconButton(
            tooltip: copy.refreshLibrary,
            onPressed: collection.refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: ItdaSpace.small),
        ],
      ),
      body: PageWidth(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                ItdaSpace.page,
                ItdaSpace.small,
                ItdaSpace.page,
                ItdaSpace.small,
              ),
              child: TextField(
                controller: _search,
                focusNode: collection.searchFocus,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: copy.searchSaved,
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: copy.clearSearch,
                          onPressed: () => setState(_search.clear),
                          icon: const Icon(Icons.close_rounded),
                        ),
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHigh,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: collection.refresh,
                child: CustomScrollView(
                  key: PageStorageKey((controller.scope, archived)),
                  primary: false,
                  physics: const AlwaysScrollableScrollPhysics(),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: ItdaSpace.page,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (query.isNotEmpty || controller.hasMore)
                              Text(
                                copy.searchLoadedHint,
                                style: theme.textTheme.bodySmall,
                              ),
                            LibraryStatus(
                              controller: controller,
                              refresh: collection.refresh,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (showEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(ItdaSpace.page),
                          child: Text(
                            query.isEmpty
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
                      sliver: SliverList.separated(
                        itemCount: rows.length,
                        itemBuilder: (context, index) =>
                            _row(context, rows[index], mode),
                        separatorBuilder: (_, _) => const Divider(height: 1),
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
    Widget tile(LibraryEntry entry) => SavedContentRow(
      key: ValueKey(entry.key),
      entry: entry,
      mode: mode,
      onOpen: widget.collection.openEntry(context, entry, mode),
      showSavedAt: row.length > 1,
    );

    if (row.length == 1) return tile(first);
    return ExpansionTile(
      key: PageStorageKey((widget.collection.controller.scope, first.linkUrl)),
      shape: const Border(),
      tilePadding: EdgeInsets.zero,
      minTileHeight: 68,
      childrenPadding: const EdgeInsetsDirectional.only(
        start: ItdaSpace.section,
      ),
      leading: SavedSourceIcon(first.type),
      title: SavedContentTitle(entryTitle(copy, first)),
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
    this.showEnvironment = true,
  });

  final LibraryController controller;
  final VoidCallback refresh;
  final bool showEnvironment;

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final inbox = controller.inbox;
    final mode = inbox?.mode ?? UploadMode.disabled;
    final issue = controller.catalogIssue;
    final environment = showEnvironment
        ? uploadEnvironmentLabel(copy, mode)
        : null;
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
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.onPrimaryContainer,
                ),
                onPressed: refresh,
                child: Text(copy.retry),
              ),
            ],
          )
        else if (inbox == null || controller.loadingCatalog)
          LinearProgressIndicator(semanticsLabel: copy.syncingLibrary),
      ],
    );
  }
}
