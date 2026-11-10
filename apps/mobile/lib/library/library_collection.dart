import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../models/content.dart';
import '../native/share_bridge.dart';
import '../widgets/library_components.dart';
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
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(archived ? copy.archiveTitle : copy.allSaved),
        actions: [
          IconButton(
            tooltip: copy.refreshLibrary,
            onPressed: refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final mode = controller.inbox?.mode ?? UploadMode.disabled;
          final groups = <Object, List<LibraryEntry>>{};
          for (final entry in controller.entries.where(
            (entry) => entry.archived == archived,
          )) {
            final url = archived ? null : entry.linkUrl;
            groups
                .putIfAbsent(url == null ? (entry.key,) : url, () => [])
                .add(entry);
          }
          final rows = groups.values.toList(growable: false);
          return PageWidth(
            child: RefreshIndicator(
              onRefresh: refresh,
              child: CustomScrollView(
                key: PageStorageKey((controller.scope, archived)),
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    sliver: SliverToBoxAdapter(
                      child: LibraryStatus(
                        controller: controller,
                        refresh: refresh,
                      ),
                    ),
                  ),
                  if (rows.isEmpty &&
                      !controller.hasMore &&
                      !controller.loadingCatalog &&
                      controller.inbox != null &&
                      controller.catalogIssue == null)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Text(
                          archived ? copy.archiveEmpty : copy.emptyLibrary,
                        ),
                      ),
                    ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    sliver: SliverList.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, index) {
                        final row = rows[index];
                        final first = row.first;
                        Widget tile(LibraryEntry entry) => _SavedRow(
                          key: ValueKey(entry.key),
                          entry: entry,
                          mode: mode,
                          onOpen: openEntry(context, entry, mode),
                        );
                        return Column(
                          children: [
                            if (row.length == 1)
                              tile(first)
                            else
                              ExpansionTile(
                                key: PageStorageKey((
                                  controller.scope,
                                  first.pebbleId,
                                )),
                                shape: const Border(),
                                leading: const Icon(Icons.link_rounded),
                                title: Text(
                                  entryTitle(copy, first),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  copy.repeatedLinkCount(row.length),
                                ),
                                childrenPadding:
                                    const EdgeInsetsDirectional.only(start: 16),
                                children: [
                                  for (final entry in row) tile(entry),
                                ],
                              ),
                            const Divider(indent: 52, endIndent: 12, height: 1),
                          ],
                        );
                      },
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
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SavedRow extends StatelessWidget {
  const _SavedRow({
    super.key,
    required this.entry,
    required this.mode,
    this.onOpen,
  });

  final LibraryEntry entry;
  final UploadMode mode;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final local = entry.local;
    final host = Uri.tryParse(entry.linkUrl ?? '')?.host;
    final source = host != null && host.isNotEmpty
        ? host
        : sourceName(copy, entry.type);
    final date = MaterialLocalizations.of(
      context,
    ).formatMediumDate(entry.savedAt.toLocal());
    final status = entry.archived
        ? null
        : entry.remote?.workflowStatus == WorkflowStatus.completed
        ? copy.completedItem
        : local == null || local.inputType == null
        ? null
        : uploadName(copy, mode, local);
    return ListTile(
      onTap: onOpen,
      leading: Icon(sourceIcon(entry.type), size: 21),
      title: Text(
        entryTitle(copy, entry),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [Text('$source · $date'), if (status != null) Text(status)],
      ),
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
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
            child: Wrap(
              spacing: 12,
              children: [
                if (environment != null)
                  Text(environment, style: theme.textTheme.labelMedium),
                if (saved)
                  Text(copy.savedCopies, style: theme.textTheme.labelMedium),
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
