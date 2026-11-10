import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/content.dart';
import 'share_bridge.dart';

enum CatalogPhase { cached, syncing, current, retrying, failed, offline }

final class CatalogSnapshot {
  const CatalogSnapshot({
    required this.items,
    required this.phase,
    this.initialized = true,
    this.hasMore = false,
    this.removed = const {},
  });

  final List<ContentItem> items;
  final CatalogPhase phase;
  final bool initialized;
  final bool hasMore;
  final Set<String> removed;
}

/// Android owns the account-scoped cache, session, and background sync.
abstract interface class CatalogBridge {
  Future<CatalogSnapshot> snapshot(
    AccountScope scope, {
    required int limit,
    required Set<String> acknowledged,
  });
  Future<void> synchronize(AccountScope scope);
}

final class AndroidCatalogBridge implements CatalogBridge {
  const AndroidCatalogBridge();

  static const _channel = MethodChannel('com.itda.itda_mobile/local_shares');

  @override
  Future<CatalogSnapshot> snapshot(
    AccountScope scope, {
    required int limit,
    required Set<String> acknowledged,
  }) async {
    final message = await _channel.invokeMethod<String>('readLibrary', {
      'owner_id': scope.ownerId,
      'realm': scope.realm,
      'limit': limit,
      'acknowledged': acknowledged.toList(),
    });
    if (message == null) throw const FormatException('Missing cached library');
    final snapshot = jsonDecode(message) as Map<String, dynamic>;
    return CatalogSnapshot(
      items: [
        for (final item in snapshot['items'] as List<dynamic>)
          ContentItem.fromJson(item as Map<String, dynamic>),
      ],
      initialized: snapshot['initialized'] as bool,
      hasMore: snapshot['has_more'] as bool,
      removed: (snapshot['removed'] as List<dynamic>).cast<String>().toSet(),
      phase: CatalogPhase.values.byName(snapshot['phase'] as String),
    );
  }

  @override
  Future<void> synchronize(AccountScope scope) =>
      _channel.invokeMethod<void>('syncLibrary', {
        'owner_id': scope.ownerId,
        'realm': scope.realm,
      });
}
