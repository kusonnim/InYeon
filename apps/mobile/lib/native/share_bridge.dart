import 'package:flutter/services.dart';

import '../models/content.dart';

/// The native receiver owns writes. Flutter reads committed outbox summaries.
abstract interface class ShareBridge {
  Future<List<PendingShare>> listPendingShares();
}

final class PendingShare {
  const PendingShare({
    required this.localId,
    required this.inputType,
    required this.label,
    required this.receivedAt,
  });

  factory PendingShare.fromMessage(Map<Object?, Object?> message) {
    if (message['upload_state'] != 'pending_upload') {
      throw const FormatException('Expected a pending local share');
    }
    return PendingShare(
      localId: message['local_id'] as String,
      inputType: InputType.values.byName(message['input_type'] as String),
      label: message['label'] as String,
      receivedAt: DateTime.fromMillisecondsSinceEpoch(
        message['received_at_ms'] as int,
        isUtc: true,
      ),
    );
  }

  final String localId;
  final InputType inputType;
  final String label;
  final DateTime receivedAt;
}

final class AndroidShareBridge implements ShareBridge {
  const AndroidShareBridge();

  static const _channel = MethodChannel('com.itda.itda_mobile/local_shares');

  @override
  Future<List<PendingShare>> listPendingShares() async {
    final entries = await _channel.invokeListMethod<Object?>(
      'listPendingShares',
    );
    return [
      for (final entry in entries ?? const [])
        PendingShare.fromMessage(entry as Map<Object?, Object?>),
    ];
  }
}

/// Notification persistence is independent of content workflow.
/// A dismiss operation must include the displayed generation and expected revision.
abstract interface class NotificationBridge {
  Future<void> reconcileFromPersistedState();
  Future<void> recordDismissal({
    required String contentId,
    required int generation,
    required int expectedRevision,
  });
}
