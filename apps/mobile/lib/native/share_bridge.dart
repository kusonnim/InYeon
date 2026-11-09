/// Planned Android boundary. Implement only after durable local writes and retry
/// identifiers exist. Never acknowledge a share based on an in-memory object.
abstract interface class ShareBridge {
  Future<String> persistIncomingShare();
  Future<void> acknowledgeAndClose(String persistedLocalId);
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
