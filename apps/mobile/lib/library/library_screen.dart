import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/content_api.dart';
import '../l10n/generated/app_localizations.dart';
import '../native/notification_bridge.dart';
import '../native/share_bridge.dart';
import '../widgets/library_components.dart';
import '../widgets/registered_content_screen.dart';
import '../widgets/saved_content_card.dart';
import 'account_screen.dart';
import 'library_controller.dart';
import 'local_content_screen.dart';
import 'sample_library_screen.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({
    super.key,
    required this.controller,
    required this.samples,
    required this.changeLanguage,
    this.notifications,
  });

  final LibraryController controller;
  final ContentApi samples;
  final Future<void> Function(Locale) changeLanguage;
  final NotificationBridge? notifications;

  Future<void> _refresh() async {
    unawaited(_refreshNotifications());
    await controller.reload(refreshCatalog: true);
  }

  Future<void> _refreshNotifications() async {
    try {
      await notifications?.refresh();
    } on PlatformException {
      // The catalog refresh is useful when Android notifications are unavailable.
    }
  }

  void _openSampleLibrary(BuildContext context) {
    Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => SampleLibraryScreen(api: samples)));
  }

  void _openAccount(BuildContext context) {
    Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => AccountScreen(
        controller: controller,
        notifications: notifications,
        changeLanguage: changeLanguage,
        openSamples: () => _openSampleLibrary(context),
      ),
    ));
  }

  VoidCallback? _openEntry(
      BuildContext context, LibraryEntry entry, UploadMode mode) {
    final local = entry.local;
    final owner = controller.scope;
    final id = entry.serverId;
    final bridge = notifications;
    final navigator = Navigator.of(context);
    void openOriginal() {
      navigator.push<void>(MaterialPageRoute(
        builder: (_) =>
            LocalContentScreen(controller: controller, localId: local!.localId),
      ));
    }

    if (id != null && owner != null && bridge != null) {
      return () => navigator.push<void>(MaterialPageRoute(
            builder: (_) => RegisteredContentScreen(
              bridge: bridge,
              target: NoticeTarget(owner.ownerId, owner.realm, id),
              initialContent: entry.remote,
              initialMode: mode,
              openOriginal: local == null ? null : openOriginal,
              onChanged: (item) => controller.updateItem(owner, item),
            ),
          ));
    }
    return local?.inputType == null ? null : openOriginal;
  }

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(copy.appName,
            style: theme.textTheme.titleLarge?.copyWith(letterSpacing: 1.1)),
        actions: [
          IconButton(
            tooltip: copy.refreshLibrary,
            onPressed: _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 12),
            child: IconButton.filledTonal(
              tooltip: copy.account,
              onPressed: () => _openAccount(context),
              icon: const Icon(Icons.person_outline_rounded),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final inbox = controller.inbox;
          final mode = inbox?.mode ?? UploadMode.disabled;
          final environment = uploadEnvironmentLabel(copy, mode);
          final entries = controller.entries;
          final grouped = <Object, List<LibraryEntry>>{};
          for (final entry in entries) {
            final url = entry.linkUrl;
            final key = url == null ? entry.key : (controller.scope, url);
            grouped.putIfAbsent(key, () => []).add(entry);
          }
          final rows = grouped.values.toList(growable: false);
          final issue = controller.catalogIssue;
          final offerSignIn =
              mode != UploadMode.disabled && inbox?.account == null;
          final waiting = inbox == null && !controller.localError ||
              controller.loadingCatalog;
          return PageWidth(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Semantics(
                              header: true,
                              child: Text(copy.libraryTitle,
                                  style: theme.textTheme.headlineLarge)),
                          const SizedBox(height: 5),
                          Text(copy.librarySubtitle,
                              style: theme.textTheme.bodyLarge),
                          if (environment != null ||
                              controller.showingSavedCopies) ...[
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 7,
                              runSpacing: 6,
                              children: [
                                if (environment != null)
                                  StatusPill(environment),
                                if (controller.showingSavedCopies)
                                  StatusPill(copy.savedCopies),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (controller.localError || issue != null)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                      sliver: SliverToBoxAdapter(
                        child: StatePanel(
                          icon: issue == CatalogIssue.connection
                              ? Icons.cloud_off_outlined
                              : Icons.info_outline_rounded,
                          title: issue == CatalogIssue.connection
                              ? copy.offlineTitle
                              : (issue == CatalogIssue.retrying
                                  ? copy.syncDelayed
                                  : copy.loadLibraryError),
                          message: controller.localError
                              ? copy.localLoadError
                              : switch (issue!) {
                                  CatalogIssue.connection =>
                                    copy.offlineLibrary,
                                  CatalogIssue.unavailable =>
                                    copy.serverLibraryError,
                                  CatalogIssue.retrying => copy.syncRetry,
                                },
                          action: _refresh,
                          actionLabel: copy.retry,
                        ),
                      ),
                    ),
                  if (entries.isEmpty && waiting)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Center(
                            child: CircularProgressIndicator(
                                semanticsLabel: copy.loadingLibrary)),
                      ),
                    ),
                  if (entries.isNotEmpty && waiting)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                      sliver: SliverToBoxAdapter(
                        child: LinearProgressIndicator(
                            semanticsLabel: copy.syncingLibrary),
                      ),
                    ),
                  if (entries.isEmpty &&
                      !waiting &&
                      !controller.localError &&
                      issue == null)
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      sliver: SliverToBoxAdapter(
                        child: StatePanel(
                          icon: Icons.bookmark_border_rounded,
                          title: copy.emptyLibrary,
                          message: copy.emptyLibraryBody,
                          actionLabel: offerSignIn
                              ? copy.signIn
                              : copy.sampleLibraryAction,
                          action: offerSignIn
                              ? () => _openAccount(context)
                              : () => _openSampleLibrary(context),
                        ),
                      ),
                    ),
                  if (entries.isNotEmpty) ...[
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
                      sliver: SliverToBoxAdapter(
                        child: Semantics(
                            header: true,
                            child: Text(copy.savedCount(entries.length),
                                style: theme.textTheme.labelLarge)),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      sliver: SliverList.builder(
                        itemCount: rows.length,
                        itemBuilder: (context, index) {
                          final row = rows[index];
                          final entry = row.first;
                          SavedContentCard card(LibraryEntry item) =>
                              SavedContentCard(
                                key: ValueKey(item.key),
                                entry: item,
                                mode: mode,
                                showSavedAt: row.length > 1,
                                onOpen: _openEntry(context, item, mode),
                              );
                          return Padding(
                            key: ValueKey((controller.scope, entry.key)),
                            padding: const EdgeInsets.only(bottom: 8),
                            child: row.length == 1
                                ? card(entry)
                                : Card(
                                    child: ExpansionTile(
                                      key: PageStorageKey(
                                          (controller.scope, entry.key)),
                                      shape: const Border(),
                                      leading: const Icon(Icons.link_rounded),
                                      title: Text(entryTitle(copy, entry),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis),
                                      subtitle: Text(
                                          copy.repeatedLinkCount(row.length)),
                                      childrenPadding:
                                          const EdgeInsets.fromLTRB(8, 0, 8, 8),
                                      children: [
                                        for (final item in row) card(item)
                                      ],
                                    ),
                                  ),
                          );
                        },
                      ),
                    ),
                  ],
                  if (controller.hasMore)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Center(
                          child: OutlinedButton(
                            onPressed: controller.loadMore,
                            child: Text(copy.loadMore),
                          ),
                        ),
                      ),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 20)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
