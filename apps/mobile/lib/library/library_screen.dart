import 'dart:async';

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
import '../widgets/saved_content_row.dart';
import 'account_screen.dart';
import 'library_collection.dart';
import 'library_controller.dart';
import 'local_content_screen.dart';
import 'sample_library_screen.dart';
import 'sign_in_screen.dart';
import 'workflow_edit.dart';

enum _Destination { home, library, account }

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
  final _searchFocus = FocusNode(debugLabel: 'Saved items search');
  _Destination _destination = _Destination.home;
  bool _archiveHover = false;

  LibraryController get controller => widget.controller;

  @override
  void dispose() {
    _searchFocus.dispose();
    super.dispose();
  }

  void _selectDestination(_Destination destination) {
    if (destination == _destination) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _destination = destination);
  }

  void _openSearch() {
    _selectDestination(_Destination.library);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _destination == _Destination.library) {
        _searchFocus.requestFocus();
      }
    });
  }

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

  void _openSignIn() {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SignInScreen(
          controller: controller,
          openAccountSettings: () {
            Navigator.of(context).pop();
            _selectDestination(_Destination.account);
          },
        ),
      ),
    );
  }

  void _openArchive() {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => LibraryCollection(
          controller: controller,
          archived: true,
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

    void openDetail(WidgetBuilder builder) {
      FocusManager.instance.primaryFocus?.unfocus();
      unawaited(navigator.push<void>(detailRoute(builder)));
    }

    if (id != null && owner != null && bridge != null) {
      return () => openDetail(
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
      );
    }
    return local?.inputType == null ? null : () => openDetail(localDetail);
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
    final colors = Theme.of(context).colorScheme;
    final destinations = [
      _home(context),
      LibraryCollection(
        controller: controller,
        archived: false,
        refresh: _refresh,
        openEntry: _openEntry,
        openArchive: _openArchive,
        searchFocus: _searchFocus,
      ),
      AccountScreen(
        controller: controller,
        notifications: widget.notifications,
        changeLanguage: widget.changeLanguage,
        openSamples: _openSamples,
      ),
    ];
    final index = _destination.index;
    return PopScope<void>(
      canPop: _destination == _Destination.home,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _selectDestination(_Destination.home);
      },
      child: Scaffold(
        body: IndexedStack(
          index: index,
          sizing: StackFit.expand,
          children: [
            for (final (i, page) in destinations.indexed)
              TickerMode(
                enabled: i == index,
                child: ExcludeFocus(excluding: i != index, child: page),
              ),
          ],
        ),
        bottomNavigationBar: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: colors.outlineVariant)),
          ),
          child: Padding(
            padding: const EdgeInsets.only(top: 1),
            child: NavigationBar(
              selectedIndex: index,
              onDestinationSelected: (index) =>
                  _selectDestination(_Destination.values[index]),
              maintainBottomViewPadding: true,
              animationDuration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              destinations: [
                NavigationDestination(
                  icon: const Icon(Icons.home_outlined),
                  selectedIcon: const Icon(Icons.home_rounded),
                  label: copy.homeDestination,
                ),
                NavigationDestination(
                  icon: const Icon(Icons.bookmarks_outlined),
                  selectedIcon: const Icon(Icons.bookmarks_rounded),
                  label: copy.libraryDestination,
                ),
                NavigationDestination(
                  icon: const Icon(Icons.person_outline_rounded),
                  selectedIcon: const Icon(Icons.person_rounded),
                  label: copy.accountDestination,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _home(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final header = ItdaPalette.homeHeader(theme.brightness);
    final viewport = MediaQuery.sizeOf(context);
    // Keep the canvas size stable while the Library keyboard is open.
    final trayHeight = (viewport.height * .28).clamp(
      viewport.width < 360 ? 244.0 : 232.0,
      252.0,
    );
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final mode = controller.inbox?.mode ?? UploadMode.disabled;
        final environment = uploadEnvironmentLabel(copy, mode);
        final entries =
            controller.entries
                .where((entry) => !entry.archived && entry.type != null)
                .toList()
              ..sort((a, b) {
                final order = b.pebbleSavedAt.compareTo(a.pebbleSavedAt);
                return order == 0 ? b.pebbleId.compareTo(a.pebbleId) : order;
              });
        return Scaffold(
          backgroundColor: colors.surface,
          appBar: AppBar(
            backgroundColor: header,
            foregroundColor: Colors.white,
            titleSpacing: 0,
            toolbarHeight: itdaToolbarHeight(context, titleSize: 30),
            systemOverlayStyle: const SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: Brightness.light,
              statusBarBrightness: Brightness.dark,
            ),
            title: PageWidth(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: ItdaSpace.page),
                child: Row(
                  children: [
                    Text(
                      '잇다',
                      semanticsLabel: copy.localeName == 'ko'
                          ? null
                          : copy.appName,
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                        fontSize: 30,
                        letterSpacing: -.6,
                      ),
                    ),
                    if (environment != null) ...[
                      const SizedBox(width: ItdaSpace.medium),
                      Expanded(
                        child: Text(
                          environment,
                          textAlign: TextAlign.end,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          body: SingleChildScrollView(
            primary: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _homeSearch(context, header),
                _homeTray(context, entries, mode, height: trayHeight),
                PageWidth(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      ItdaSpace.page,
                      ItdaSpace.small,
                      ItdaSpace.page,
                      ItdaSpace.section,
                    ),
                    child: _recentSaves(context, entries.take(3), mode),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _homeSearch(BuildContext context, Color header) {
    final copy = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return ColoredBox(
      color: header,
      child: PageWidth(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            ItdaSpace.page,
            ItdaSpace.tiny,
            ItdaSpace.page,
            ItdaSpace.large,
          ),
          child: SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              style: TextButton.styleFrom(
                backgroundColor: ItdaPalette.homeSearch(theme.brightness),
                foregroundColor: colors.onSurfaceVariant,
                overlayColor: colors.primary,
                alignment: AlignmentDirectional.centerStart,
                minimumSize: const Size(ItdaSpace.touchTarget, 52),
                padding: const EdgeInsets.symmetric(
                  horizontal: ItdaSpace.large,
                  vertical: ItdaSpace.medium,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(ItdaSpace.medium),
                ),
                side: theme.brightness == Brightness.dark
                    ? BorderSide(color: colors.primary)
                    : null,
                textStyle: theme.textTheme.bodyLarge,
              ),
              onPressed: _openSearch,
              icon: Icon(
                Icons.search_rounded,
                color: colors.onPrimaryContainer,
              ),
              label: Text(copy.searchSaved),
            ),
          ),
        ),
      ),
    );
  }

  Widget _homeTray(
    BuildContext context,
    Iterable<LibraryEntry> entries,
    UploadMode mode, {
    required double height,
  }) {
    final copy = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final signedOut = mode != UploadMode.disabled && controller.scope == null;
    return ColoredBox(
      color: ItdaPalette.traySurface(theme.brightness),
      child: PageWidth(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: ItdaSpace.page),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LibraryStatus(
                controller: controller,
                refresh: _refresh,
                showEnvironment: false,
              ),
              if (signedOut)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: colors.onPrimaryContainer,
                    ),
                    onPressed: _openSignIn,
                    child: Text(copy.signIn),
                  ),
                ),
              SizedBox(
                height: height,
                child: PebbleTray(
                  scope: (controller.scope, mode),
                  items: [
                    for (final entry in entries.take(10))
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
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  0,
                  ItdaSpace.tiny,
                  0,
                  ItdaSpace.medium,
                ),
                child: Center(
                  child: OutlinedButton.icon(
                    key: _archiveDock,
                    style: OutlinedButton.styleFrom(
                      backgroundColor: _archiveHover
                          ? colors.primary
                          : colors.surface,
                      foregroundColor: _archiveHover
                          ? colors.onPrimary
                          : colors.onPrimaryContainer,
                      minimumSize: const Size(128, ItdaSpace.touchTarget),
                      side: BorderSide(color: colors.primary),
                    ),
                    onPressed: _openArchive,
                    icon: const Icon(Icons.archive_outlined, size: 19),
                    label: Text(copy.archiveTitle),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _recentSaves(
    BuildContext context,
    Iterable<LibraryEntry> entries,
    UploadMode mode,
  ) {
    final copy = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  const SizedBox(
                    width: 3,
                    height: 18,
                    child: ColoredBox(color: ItdaPalette.brightBlue),
                  ),
                  const SizedBox(width: ItdaSpace.small),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        copy.recentSaved,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            TextButton.icon(
              iconAlignment: IconAlignment.end,
              onPressed: () => _selectDestination(_Destination.library),
              icon: const Icon(Icons.chevron_right, size: 18),
              label: Text(copy.viewAllSaved),
            ),
          ],
        ),
        if (entries.isEmpty &&
            controller.inbox != null &&
            !controller.loadingCatalog &&
            controller.catalogIssue == null) ...[
          Text(copy.emptyLibrary, style: theme.textTheme.bodySmall),
          if (mode == UploadMode.disabled)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: _openSamples,
                child: Text(copy.sampleLibraryAction),
              ),
            ),
        ],
        for (final entry in entries) ...[
          const Divider(height: 1),
          SavedContentRow(
            key: ValueKey(('recent', entry.pebbleId)),
            entry: entry,
            mode: mode,
            onOpen: _openEntry(context, entry, mode),
          ),
        ],
      ],
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
