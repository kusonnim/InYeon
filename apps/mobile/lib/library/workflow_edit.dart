import 'package:flutter/services.dart';

import '../models/content.dart';
import '../native/notification_bridge.dart';

WorkflowStatus nextWorkflow(WorkflowStatus status) => switch (status) {
  WorkflowStatus.pending || WorkflowStatus.completed => WorkflowStatus.archived,
  WorkflowStatus.archived => WorkflowStatus.pending,
};

Future<RegisteredContent> changeWorkflow(
  NotificationBridge bridge,
  NoticeTarget target,
  ContentItem item,
  WorkflowStatus destination,
) async {
  if (item.id != target.contentId ||
      item.userId != target.ownerId ||
      nextWorkflow(item.workflowStatus) != destination) {
    throw PlatformException(code: 'workflow_unavailable');
  }
  final result = await bridge.edit(
    target,
    ContentPatch(expectedVersion: item.version, workflowStatus: destination),
  );
  final updated = result.content;
  if (updated.id != item.id ||
      updated.userId != item.userId ||
      updated.workflowStatus != destination ||
      updated.version <= item.version) {
    throw PlatformException(code: 'invalid_server_response');
  }
  return result;
}
