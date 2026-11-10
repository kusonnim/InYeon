import 'package:flutter/services.dart';

/// A source URL from a content item or recommendation.
final class ExternalLink {
  ExternalLink(this.value) : _uri = Uri.tryParse(value);

  static const _channel = MethodChannel('com.itda.itda_mobile/local_shares');
  static final _invalidCharacters =
      RegExp(r'[\s\u0000-\u001f\u007f\\]|%(?![0-9a-fA-F]{2})');
  static final _privateStorage = RegExp(
    r'/storage/v1/object/(?:upload/)?(?:sign|authenticated)(?:/|$)',
    caseSensitive: false,
  );
  static final _parameters = RegExp(r'[&;?]');
  static const _credentialKeys = {
    'access_token',
    'refresh_token',
    'id_token',
    'authorization',
    'api_key',
    'apikey',
    'password',
    'token',
    'signature',
    'sig',
    'x-amz-signature',
    'x-goog-signature',
  };

  final String value;
  final Uri? _uri;

  late final bool isProtected = _containsCredentials();
  late final bool canOpen = switch (_uri) {
    final uri? => (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.hasAuthority &&
        uri.host.isNotEmpty &&
        (!uri.hasPort || (uri.port > 0 && uri.port <= 65535)) &&
        !_invalidCharacters.hasMatch(value) &&
        !isProtected,
    null => false,
  };

  bool _containsCredentials() {
    final uri = _uri;
    if (uri == null) return false;
    try {
      if (uri.authority.contains('@') ||
          _privateStorage.hasMatch(Uri.decodeComponent(uri.path))) {
        return true;
      }
      return [uri.query, uri.fragment]
          .expand((part) => part.split(_parameters))
          .any((part) {
        final separator = part.indexOf('=');
        if (separator < 0) return false;
        final key = Uri.decodeQueryComponent(part.substring(0, separator));
        return _credentialKeys.contains(key.toLowerCase());
      });
    } on FormatException {
      return true;
    } on ArgumentError {
      return true;
    }
  }

  Future<bool> open() async {
    if (!canOpen) return false;
    try {
      return await _channel.invokeMethod<bool>('openExternalLink', value) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
