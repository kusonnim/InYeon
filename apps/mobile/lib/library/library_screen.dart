import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/content_api.dart';
import '../l10n/generated/app_localizations.dart';
import '../models/content.dart';
import '../native/notification_bridge.dart';
import '../native/share_bridge.dart';
import '../tray/pebble_tray.dart';
import '../widgets/itda_theme.dart';
import '../widgets/library_components.dart';
import '../widgets/registered_content_screen.dart';
import 'account_screen.dart';
import 'library_collection.dart';
import 'library_controller.dart';
import 'local_content_screen.dart';
import 'sample_library_screen.dart';
import 'sign_in_screen.dart';
import 'workflow_edit.dart';

class LibraryScreen extends StatefulWidget {
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

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}
class _LibraryScreenState extends State<LibraryScreen> {
  final _archiveDock = GlobalKey();
  final _archiveRequests = <(AccountScope, String)>{};
  bool _archiveHover = false;

  LibraryController get controller => widget.controller;

  Future<void> _refresh() async {
    unawaited(_refreshNotifications());
    await controller.reload(refreshCatalog: true);
  }

  Future<void> _refreshNotifications() async {
    try {
      await widget.notifications?.refresh();
    } on PlatformException {
      // The catalog refresh still works when notifications are unavailable.
    }
  }

  void _openSamples() {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SampleLibraryScreen(api: widget.samples),
      ),
    );
  }

  void _openAccount({bool replace = false}) {
    final route = MaterialPageRoute<void>(
      builder: (_) => AccountScreen(
        controller: controller,
        notifications: widget.notifications,
        changeLanguage: widget.changeLanguage,
        openSamples: _openSamples,
      ),
    );
    final navigator = Navigator.of(context);
    if (replace) {
      navigator.pushReplacement<void, void>(route);
    } else {
      navigator.push<void>(route);
    }
  }

  void _openSignIn() {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SignInScreen(
          controller: controller,
          openAccountSettings: () => _openAccount(replace: true),
        ),
      ),
    );
  }

  void _openCollection({required bool archived}) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => LibraryCollection(
          controller: controller,
          archived: archived,
          refresh: _refresh,
          openEntry: _openEntry,
        ),
      ),
    );
  }

  VoidCallback? _openEntry(
    BuildContext context,
    LibraryEntry entry,
    UploadMode mode, {
    bool fromPebble = false,
  }) {
    final local = entry.local;
    final owner = controller.scope;
    final id = entry.serverId;
    final bridge = widget.notifications;
    final navigator = Navigator.of(context);
    final reduceMotion = fromPebble && MediaQuery.disableAnimationsOf(context);
    Widget localDetail(BuildContext _) =>
        LocalContentScreen(controller: controller, localId: local!.localId);

    Route<void> detailRoute(WidgetBuilder builder) => fromPebble
        ? _pebbleDetailRoute(builder, reduceMotion: reduceMotion)
        : MaterialPageRoute<void>(builder: builder);

    if (id != null && owner != null && bridge != null) {
      return () => navigator.push<void>(
            detailRoute(
              (_) => RegisteredContentScreen(
                bridge: bridge,
                target: NoticeTarget(owner.ownerId, owner.realm, id),
                library: controller,
                initialContent: entry.remote,
                initialMode: mode,
                openOriginal: local == null
                    ? null
                    : () => navigator.push<void>(
                        MaterialPageRoute(builder: localDetail),
                      ),
                onChanged: (item) => controller.updateItem(owner, item),
              ),
            ),
          );
    }
    return local?.inputType == null
        ? null
        : () => navigator.push<void>(detailRoute(localDetail));
  }

  LibraryEntry? _activeEntry(String id) => controller.entries
      .where((entry) => entry.pebbleId == id && !entry.archived)
      .firstOrNull;

  void _openPebble(String id) {
    final entry = _activeEntry(id);
    if (entry != null) {
      _openEntry(
        context,
        entry,
        controller.inbox?.mode ?? UploadMode.disabled,
        fromPebble: true,
      )?.call();
    }
  }

  bool _overArchiveDock(Offset point) {
    final box = _archiveDock.currentContext?.findRenderObject();
    return box is RenderBox &&
        (Offset.zero & box.size).contains(box.globalToLocal(point));
  }

  void _showStatus(String message) => ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _archive(String id) async {
    final entry = _activeEntry(id);
    if (entry == null) return;
    final item = entry.remote;
    final owner = controller.scope;
    final bridge = widget.notifications;
    final copy = AppLocalizations.of(context);
    if (item == null || owner == null || bridge == null) {
      _showStatus(copy.workflowNeedsSync);
      return;
    }
    final request = (owner, item.id);
    if (!_archiveRequests.add(request)) return;
    try {
      final updated = await changeWorkflow(
        bridge,
        NoticeTarget(owner.ownerId, owner.realm, item.id),
        item,
        WorkflowStatus.archived,
      );
      if (!mounted || controller.scope != owner) return;
      controller.updateItem(owner, updated.content);
      _showStatus(AppLocalizations.of(context).archiveConfirmed);
    } on PlatformException catch (error) {
      if (!mounted || controller.scope != owner) return;
      final copy = AppLocalizations.of(context);
      _showStatus(switch (error.code) {
        'version_conflict' => copy.workflowConflict,
        'network_unavailable' ||
        'authentication_required' ||
        'account_changed' => copy.workflowUnavailable,
        _ => copy.operationUnconfirmed,
      });
      if (error.code == 'version_conflict')
        unawaited(controller.reload(refreshCatalog: true));
    } on FormatException {
      if (mounted && controller.scope == owner) {
        _showStatus(AppLocalizations.of(context).operationUnconfirmed);
      }
    } finally {
      _archiveRequests.remove(request);
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final mode = controller.inbox?.mode ?? UploadMode.disabled;
        final signedOut =
            mode != UploadMode.disabled && controller.scope == null;
        final screenWidth = MediaQuery.sizeOf(context).width;
        final actionTextSize = theme.textTheme.labelLarge!.fontSize!;
        final entries = controller.entries
            .where((entry) => !entry.archived)
            .toList();
        final pebbles = entries.where((entry) => entry.type != null).toList()
          ..sort((a, b) {
            final order = b.pebbleSavedAt.compareTo(a.pebbleSavedAt);
            return order == 0 ? b.pebbleId.compareTo(a.pebbleId) : order;
          });
        return Scaffold(
          appBar: AppBar(
            title: FittedBox(
              alignment: AlignmentDirectional.centerStart,
              fit: BoxFit.scaleDown,
              child: Text(
                '잇다',
                semanticsLabel: copy.localeName == 'ko' ? null : copy.appName,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontSize: 26,
                  letterSpacing: -.6,
                ),
              ),
            ),
            toolbarHeight: math.max(
              kToolbarHeight,
              MediaQuery.textScalerOf(context).scale(actionTextSize) * 2.4 +
                  ItdaSpace.large,
            ),
            actions: [
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: screenWidth * .40),
                child: TextButton(
                  onPressed: () => _openCollection(archived: false),
                  child: Text(copy.allSaved, textAlign: TextAlign.center),
                ),
              ),
              if (signedOut)
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: screenWidth * .32),
                  child: TextButton(
                    onPressed: _openSignIn,
                    child: Text(copy.signIn, textAlign: TextAlign.center),
                  ),
                )
              else
                IconButton(
                  tooltip: copy.account,
                  onPressed: _openAccount,
                  icon: const Icon(Icons.person_outline_rounded),
                ),
              const SizedBox(width: ItdaSpace.small),
            ],
          ),
          body: PageWidth(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: ItdaSpace.page),
              child: Column(
                children: [
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        PebbleTray(
                          scope: (controller.scope, mode),
                          items: [
                            for (final entry in pebbles.take(10))
                              (
                                id: entry.pebbleId,
                                title: entryTitle(copy, entry),
                                canArchive:
                                    entry.remote != null &&
                                    controller.scope != null &&
                                    widget.notifications != null,
                              ),
                          ],
                          onOpen: _openPebble,
                          isOverArchive: _overArchiveDock,
                          onArchiveHover: (value) =>
                              setState(() => _archiveHover = value),
                          onArchive: _archive,
                        ),
                        if (entries.isEmpty &&
                            !controller.loadingCatalog &&
                            controller.inbox != null &&
                            controller.catalogIssue == null)
                          Center(
                            child: SingleChildScrollView(
                              child: Column(
                                children: [
                                  Text(
                                    copy.emptyLibrary,
                                    textAlign: TextAlign.center,
                                  ),
                                  if (mode == UploadMode.disabled)
                                    TextButton(
                                      onPressed: _openSamples,
                                      child: Text(copy.sampleLibraryAction),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: LibraryStatus(
                            controller: controller,
                            refresh: _refresh,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(
                      top: ItdaSpace.small,
                      bottom: ItdaSpace.medium,
                    ),
                    child: TextButton.icon(
                      key: _archiveDock,
                      style: TextButton.styleFrom(
                        backgroundColor: _archiveHover
                            ? theme.colorScheme.primaryContainer
                            : theme.colorScheme.surfaceContainerHighest,
                        minimumSize: const Size(128, ItdaSpace.touchTarget),
                      ),
                      onPressed: () => _openCollection(archived: true),
                      icon: const Icon(Icons.archive_outlined, size: 19),
                      label: Text(copy.archiveTitle),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

PageRoute<void> _pebbleDetailRoute(
  WidgetBuilder builder, {
  required bool reduceMotion,
}) => PageRouteBuilder<void>(
  transitionDuration: reduceMotion
      ? Duration.zero
      : const Duration(milliseconds: 200),
  reverseTransitionDuration: reduceMotion
      ? Duration.zero
      : const Duration(milliseconds: 160),
  pageBuilder: (context, _, _) => builder(context),
  transitionsBuilder: (_, animation, _, child) {
    if (reduceMotion) return child;
    final eased = animation.drive(CurveTween(curve: Curves.easeInOutCubic));
    return FadeTransition(
      opacity: eased,
      child: ScaleTransition(
        scale: eased.drive(Tween<double>(begin: .985, end: 1)),
        child: child,
      ),
    );
  },
);
