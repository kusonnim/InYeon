import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/content.dart';
import 'share_bridge.dart';

abstract interface class NotificationBridge {
  Stream<void> get changes;
  Future<NoticeNavigation?> takeNavigation();
  Future<RegisteredContent> details(NoticeTarget target);
  Future<NoticeStatus> status(NoticeTarget target);
  Future<RegisteredContent> edit(NoticeTarget target, ContentPatch patch);
  Future<void> restore(NoticeTarget target);
  Future<void> refresh();
  Future<void> enable();
}

final class NoticeTarget {
  const NoticeTarget(this.ownerId, this.realm, this.contentId);

  factory NoticeTarget.fromMessage(Map<Object?, Object?> message) =>
      NoticeTarget(
        message['owner_id'] as String,
        message['realm'] as String,
        message['content_id'] as String,
      );

  final String ownerId;
  final String realm;
  final String contentId;

  Map<String, String> toMessage() => {
        'owner_id': ownerId,
        'realm': realm,
        'content_id': contentId,
      };
}

enum NoticeDestination { details, edit }

final class NoticeNavigation {
  const NoticeNavigation(this.target, this.destination);

  final NoticeTarget target;
  final NoticeDestination destination;
}

final class NoticeStatus {
  const NoticeStatus({
    this.dismissed = false,
    this.canRestore = false,
    this.pending,
    this.error,
    this.known = true,
  });

  factory NoticeStatus.fromMessage(Map<Object?, Object?>? message) =>
      NoticeStatus(
        dismissed: message?['dismissed'] == true,
        canRestore: message?['can_restore'] == true,
        pending: message?['pending'] as String?,
        error: message?['error'] as String?,
        known: message?.containsKey('dismissed') == true,
      );

  final bool dismissed;
  final bool canRestore;
  final String? pending;
  final String? error;
  final bool known;
}

final class RegisteredContent {
  const RegisteredContent(this.content, this.mode, this.notice);

  factory RegisteredContent.fromMessage(Map<Object?, Object?> message) =>
      RegisteredContent(
        ContentItem.fromJson(
          jsonDecode(message['content'] as String) as Map<String, dynamic>,
        ),
        UploadMode.values.byName(message['mode'] as String),
        NoticeStatus.fromMessage(message['notice'] as Map<Object?, Object?>?),
      );

  final ContentItem content;
  final UploadMode mode;
  final NoticeStatus notice;
}

final class AndroidNotificationBridge implements NotificationBridge {
  const AndroidNotificationBridge();

  static const _channel = MethodChannel('com.itda.itda_mobile/local_shares');

  @override
  Stream<void> get changes => AndroidShareBridge.changeEvents;

  @override
  Future<NoticeNavigation?> takeNavigation() async {
    final message = await _channel.invokeMapMethod<Object?, Object?>(
      'takeNoticeNavigation',
    );
    if (message == null) return null;
    return NoticeNavigation(
      NoticeTarget.fromMessage(message),
      NoticeDestination.values.byName(message['destination'] as String),
    );
  }

  @override
  Future<RegisteredContent> details(NoticeTarget target) =>
      _content('noticeDetails', target.toMessage());

  @override
  Future<NoticeStatus> status(NoticeTarget target) async =>
      NoticeStatus.fromMessage(await _channel.invokeMapMethod<Object?, Object?>(
        'noticeStatus',
        target.toMessage(),
      ));

  @override
  Future<RegisteredContent> edit(NoticeTarget target, ContentPatch patch) =>
      _content('editNoticeContent', {...target.toMessage(), ...patch.toJson()});

  Future<RegisteredContent> _content(
    String method,
    Map<String, Object?> arguments,
  ) async {
    final message = await _channel.invokeMapMethod<Object?, Object?>(
      method,
      arguments,
    );
    if (message == null)
      throw const FormatException('Missing content response');
    return RegisteredContent.fromMessage(message);
  }

  @override
  Future<void> restore(NoticeTarget target) =>
      _channel.invokeMethod<void>('restoreNotice', target.toMessage());

  @override
  Future<void> refresh() => _channel.invokeMethod<void>('refreshNotices');

  @override
  Future<void> enable() => _channel.invokeMethod<void>('enableNotices');
}
