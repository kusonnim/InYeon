import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/content.dart';
import '../native/catalog_bridge.dart';
import '../native/share_bridge.dart';

enum CatalogIssue { connection, unavailable, retrying }

final class LibraryEntry {
  const LibraryEntry(this.key, {this.local, this.remote});

  final String key;
  final LocalShare? local;
  final ContentItem? remote;

  DateTime get savedAt => remote?.createdAt ?? local!.receivedAt;
  InputType? get type => remote?.inputType ?? local?.inputType;
  String? get linkUrl {
    if (type != InputType.url) return null;
    final url = local?.sourceUrl ?? remote?.sourceUrl;
    return url == null || url.isEmpty ? null : url;
  }

  String? get serverId => remote?.id ?? local?.serverContentId;
}

class LibraryController extends ChangeNotifier {
  LibraryController(this.shares, this.catalog) {
    if (shares == null) {
      _inbox = const LocalInbox(mode: UploadMode.disabled, shares: []);
    } else {
      _subscription = shares!.changes.listen(
        (_) => unawaited(reload()),
        onError: (Object _) {},
      );
    }
  }

  final ShareBridge? shares;
  final CatalogBridge? catalog;
  StreamSubscription<void>? _subscription;
  LocalInbox? _inbox;
  final _contents = <String, ContentItem>{};
  CatalogSnapshot? _snapshot;
  int _limit = 10;
  int _inboxRequest = 0;
  int _catalogRequest = 0;
  bool _refreshRequested = false;
  bool _disposed = false;
  bool _localError = false;
  CatalogIssue? _cacheIssue;

  LocalInbox? get inbox => _inbox;
  AccountScope? get scope => _inbox?.account?.scope;
  bool get localError => _localError;
  bool get loadingCatalog =>
      _snapshot?.phase == CatalogPhase.syncing ||
      (_snapshot?.phase == CatalogPhase.cached &&
          _snapshot?.initialized == false) ||
      (_snapshot == null &&
          _cacheIssue == null &&
          scope != null &&
          catalog != null);
  bool get hasMore => _snapshot?.hasMore == true;
  bool get showingSavedCopies =>
      _snapshot?.initialized == true &&
      _snapshot?.phase != CatalogPhase.current;
  CatalogIssue? get catalogIssue =>
      _cacheIssue ??
      switch (_snapshot?.phase) {
        CatalogPhase.offline => CatalogIssue.connection,
        CatalogPhase.retrying => CatalogIssue.retrying,
        CatalogPhase.failed => CatalogIssue.unavailable,
        _ => null,
      };

  List<LibraryEntry> get entries {
    final merged = <String, LibraryEntry>{};
    for (final share in _inbox?.shares ?? const <LocalShare>[]) {
      if (_snapshot?.removed.contains(share.serverContentId) == true) continue;
      final key = _entryKey(share);
      merged.putIfAbsent(key, () => LibraryEntry(key, local: share));
    }
    for (final content in _contents.values) {
      final key = 'server:${content.id}';
      merged[key] =
          LibraryEntry(key, local: merged[key]?.local, remote: content);
    }
    return merged.values.toList()
      ..sort((a, b) {
        final order = b.savedAt.compareTo(a.savedAt);
        return order == 0 ? b.key.compareTo(a.key) : order;
      });
  }

  String _entryKey(LocalShare share) =>
      scope != null && share.serverContentId != null
          ? 'server:${share.serverContentId}'
          : 'local:${share.localId}';

  Future<void> reload({bool refreshCatalog = false}) async {
    if (shares == null || _disposed) return;
    _refreshRequested = _refreshRequested || refreshCatalog;
    final request = ++_inboxRequest;
    try {
      final next = await shares!.listInbox();
      if (_disposed || request != _inboxRequest) return;
      final changedScope = next.account?.scope != scope;
      if (changedScope) _clearCatalog();
      _inbox = next;
      _localError = false;
      final shouldRefresh = _refreshRequested;
      _refreshRequested = false;
      notifyListeners();
      if (scope != null && catalog != null)
        await _loadCatalog(synchronize: shouldRefresh);
    } catch (_) {
      if (_disposed || request != _inboxRequest) return;
      _inbox = null;
      _localError = true;
      _clearCatalog();
      notifyListeners();
    }
  }

  Future<void> loadMore() async {
    if (!hasMore) return;
    _limit += 10;
    await _loadCatalog();
  }

  Future<void> _loadCatalog({bool synchronize = false}) async {
    final owner = scope;
    if (owner == null || catalog == null) return;
    final request = ++_catalogRequest;
    try {
      if (synchronize) await catalog!.synchronize(owner);
      if (!_current(request, owner)) return;
      final snapshot = await catalog!.snapshot(
        owner,
        limit: _limit,
        acknowledged: _acknowledgments(_inbox),
      );
      if (!_current(request, owner)) return;
      if (snapshot.items.any((item) => item.userId != owner.ownerId)) {
        throw const FormatException('Unexpected catalog owner');
      }
      final next = <String, ContentItem>{
        for (final item in snapshot.items)
          item.id: _newer(_contents[item.id], item),
      };
      _contents.clear();
      _contents.addAll(next);
      _snapshot = snapshot;
      _cacheIssue = null;
    } on PlatformException catch (error) {
      if (!_current(request, owner)) return;
      switch (error.code) {
        case 'authentication_required':
        case 'account_changed':
          hideAccountData();
        case 'network_unavailable':
          _cacheIssue = CatalogIssue.connection;
        default:
          _cacheIssue = CatalogIssue.unavailable;
      }
    } catch (_) {
      if (_current(request, owner)) _cacheIssue = CatalogIssue.unavailable;
    } finally {
      if (_current(request, owner)) notifyListeners();
    }
  }

  void updateItem(AccountScope owner, ContentItem item) {
    if (_disposed ||
        owner != scope ||
        item.userId != owner.ownerId ||
        _snapshot?.removed.contains(item.id) == true) return;
    _contents[item.id] = _newer(_contents[item.id], item);
    notifyListeners();
  }

  void hideAccountData() {
    ++_inboxRequest;
    _inbox = null;
    _clearCatalog();
    notifyListeners();
  }

  void _clearCatalog() {
    ++_catalogRequest;
    _contents.clear();
    _snapshot = null;
    _limit = 10;
    _cacheIssue = null;
  }

  bool _current(int request, AccountScope owner) =>
      !_disposed && request == _catalogRequest && owner == scope;

  Set<String> _acknowledgments(LocalInbox? inbox) => {
        for (final share in inbox?.shares ?? const <LocalShare>[])
          if (share.serverContentId != null) share.serverContentId!,
      };

  ContentItem _newer(ContentItem? known, ContentItem incoming) {
    if (known == null) return incoming;
    if (known.version > incoming.version) return known;
    if (known.version == incoming.version &&
        known.updatedAt.isAfter(incoming.updatedAt)) {
      return known;
    }
    return incoming;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
