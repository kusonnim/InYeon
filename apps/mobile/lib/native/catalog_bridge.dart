import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/content.dart';
import 'share_bridge.dart';

/// The Android session signs and scopes catalog requests without exposing tokens.
abstract interface class CatalogBridge {
  Future<ContentPage> listContents(AccountScope scope, {String? cursor});
}

final class AndroidCatalogBridge implements CatalogBridge {
  const AndroidCatalogBridge();

  static const _channel = MethodChannel('com.itda.itda_mobile/local_shares');

  @override
  Future<ContentPage> listContents(AccountScope scope, {String? cursor}) async {
    final message = await _channel.invokeMethod<String>('listCatalog', {
      'owner_id': scope.ownerId,
      'realm': scope.realm,
      if (cursor != null) 'cursor': cursor,
    });
    if (message == null) throw const FormatException('Missing catalog page');
    return ContentPage.fromJson(jsonDecode(message) as Map<String, dynamic>);
  }
}
