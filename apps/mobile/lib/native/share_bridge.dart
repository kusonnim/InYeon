import 'package:flutter/services.dart';

import '../models/content.dart';

/// The Android outbox owns storage, user sessions, and scheduled work.
abstract interface class ShareBridge {
  Stream<void> get changes;
  Future<LocalInbox> listInbox();
  Future<void> signIn(String email, String password);
  Future<void> signOut();
  Future<void> assignShare(String localId, String accountId);
}

enum UploadMode { disabled, mock, live }

enum LocalUploadState {
  pending('pending_upload'),
  uploading('uploading'),
  retryWaiting('retry_waiting'),
  authenticationRequired('authentication_required'),
  synchronized('synchronized'),
  permanentFailure('permanent_failure');

  const LocalUploadState(this.wire);
  final String wire;
}

final class UploadAccount {
  const UploadAccount({required this.id, required this.email, this.realm});

  final String id;
  final String email;
  final String? realm;
}

final class LocalInbox {
  const LocalInbox({
    required this.mode,
    this.account,
    required this.shares,
    this.notificationsEnabled = false,
  });

  factory LocalInbox.fromMessage(Map<Object?, Object?> message) {
    final account = message['account'] as Map<Object?, Object?>?;
    return LocalInbox(
      mode: UploadMode.values.byName(message['mode'] as String),
      account: account == null
          ? null
          : UploadAccount(
              id: account['id'] as String,
              email: account['email'] as String,
              realm: account['realm'] as String?,
            ),
      shares: [
        for (final share in message['shares'] as List<Object?>)
          LocalShare.fromMessage(share as Map<Object?, Object?>),
      ],
      notificationsEnabled: message['notifications_enabled'] == true,
    );
  }

  final UploadMode mode;
  final UploadAccount? account;
  final List<LocalShare> shares;
  final bool notificationsEnabled;
}

final class LocalShare {
  const LocalShare({
    required this.localId,
    required this.inputType,
    required this.label,
    required this.receivedAt,
    required this.uploadState,
    this.canAssign = false,
    this.lastError,
    this.serverContentId,
  });

  factory LocalShare.fromMessage(Map<Object?, Object?> message) {
    final type = message['input_type'] as String?;
    return LocalShare(
      localId: message['local_id'] as String,
      inputType: type == null ? null : InputType.values.byName(type),
      label: message['label'] as String,
      receivedAt: DateTime.fromMillisecondsSinceEpoch(
        message['received_at_ms'] as int,
        isUtc: true,
      ),
      uploadState: LocalUploadState.values.singleWhere(
        (state) => state.wire == message['upload_state'],
      ),
      canAssign: message['can_assign'] as bool,
      lastError: message['last_error'] as String?,
      serverContentId: message['server_content_id'] as String?,
    );
  }

  final String localId;
  final InputType? inputType;
  final String label;
  final DateTime receivedAt;
  final LocalUploadState uploadState;
  final bool canAssign;
  final String? lastError;
  final String? serverContentId;
}

final class AndroidShareBridge implements ShareBridge {
  const AndroidShareBridge();

  static const _channel = MethodChannel('com.itda.itda_mobile/local_shares');
  static const _updates = EventChannel('com.itda.itda_mobile/share_updates');
  static final changeEvents =
      _updates.receiveBroadcastStream().map<void>((_) {});

  @override
  Stream<void> get changes => changeEvents;

  @override
  Future<LocalInbox> listInbox() async {
    final message = await _channel.invokeMapMethod<Object?, Object?>(
      'listLocalInbox',
    );
    if (message == null) throw const FormatException('Missing local inbox');
    return LocalInbox.fromMessage(message);
  }

  @override
  Future<void> signIn(String email, String password) => _channel
      .invokeMethod<void>('signIn', {'email': email, 'password': password});

  @override
  Future<void> signOut() => _channel.invokeMethod<void>('signOut');

  @override
  Future<void> assignShare(String localId, String accountId) =>
      _channel.invokeMethod<void>(
        'assignShare',
        {'local_id': localId, 'account_id': accountId},
      );
}
