import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/content.dart';
import '../native/catalog_bridge.dart';
import '../native/share_bridge.dart';

enum CatalogIssue { connection, unavailable, expiredCursor }

final class LibraryEntry {
  const LibraryEntry(this.key, {this.local, this.remote});

  final String key;
  final LocalShare? local;
  final ContentItem? remote;

  DateTime get savedAt => remote?.createdAt ?? local!.receivedAt;
  InputType? get type => remote?.inputType ?? local?.inputType;
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
  String? _cursor;
  int _inboxRequest = 0;
  int _catalogRequest = 0;
  bool _refreshRequested = false;
  bool _disposed = false;
  bool _localError = false;
  bool _loadingCatalog = false;
  CatalogIssue? _catalogIssue;

  LocalInbox? get inbox => _inbox;
  AccountScope? get scope => _inbox?.account?.scope;
  bool get localError => _localError;
  bool get loadingCatalog => _loadingCatalog;
  bool get hasMore => _cursor != null;
  CatalogIssue? get catalogIssue => _catalogIssue;

  List<LibraryEntry> get entries {
    final merged = <String, LibraryEntry>{};
    for (final share in _inbox?.shares ?? const <LocalShare>[]) {
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
      final previousIds = _acknowledgments(_inbox);
      final hasNewAck =
          _acknowledgments(next).difference(previousIds).isNotEmpty;
      if (changedScope) _clearCatalog();
      _inbox = next;
      _localError = false;
      final shouldRefresh = _refreshRequested || changedScope || hasNewAck;
      _refreshRequested = false;
      if (shouldRefresh && scope != null && catalog != null) {
        await _loadCatalog();
      } else {
        notifyListeners();
      }
    } catch (_) {
      if (_disposed || request != _inboxRequest) return;
      _inbox = null;
      _localError = true;
      _clearCatalog();
      notifyListeners();
    }
  }

  Future<void> loadMore() async {
    final cursor = _cursor;
    if (cursor != null && !_loadingCatalog) await _loadCatalog(cursor: cursor);
  }

  Future<void> _loadCatalog({String? cursor}) async {
    final owner = scope;
    if (owner == null || catalog == null) return;
    final request = ++_catalogRequest;
    _loadingCatalog = true;
    _catalogIssue = null;
    notifyListeners();
    try {
      final page = await catalog!.listContents(owner, cursor: cursor);
      if (!_current(request, owner)) return;
      if (page.items.any((item) => item.userId != owner.ownerId)) {
        throw const FormatException('Unexpected catalog owner');
      }
      final next = <String, ContentItem>{
        for (final item in page.items)
          item.id: _newer(_contents[item.id], item),
      };
      if (cursor == null) _contents.clear();
      _contents.addAll(next);
      _cursor = page.nextCursor;
    } on PlatformException catch (error) {
      if (!_current(request, owner)) return;
      switch (error.code) {
        case 'authentication_required':
        case 'account_changed':
          _clearCatalog();
          notifyListeners();
          unawaited(reload());
        case 'network_unavailable':
          _catalogIssue = CatalogIssue.connection;
        case 'invalid_cursor':
          _cursor = null;
          _catalogIssue = CatalogIssue.expiredCursor;
        default:
          _catalogIssue = CatalogIssue.unavailable;
      }
    } catch (_) {
      if (_current(request, owner)) _catalogIssue = CatalogIssue.unavailable;
    } finally {
      if (_current(request, owner)) {
        _loadingCatalog = false;
        notifyListeners();
      }
    }
  }

  void updateItem(AccountScope owner, ContentItem item) {
    if (_disposed || owner != scope || item.userId != owner.ownerId) return;
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
    _cursor = null;
    _catalogIssue = null;
    _loadingCatalog = false;
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
