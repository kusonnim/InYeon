package com.itda.itda_mobile

/**
 * Unregistered design boundary, deliberately outside the generated Android runner.
 * No Android SEND intent filter may be enabled before this durable handoff works.
 * Implement attachment URI permission handling and private-file copying before ack.
 */
interface ShareIngestionContract {
    // Must commit original payload, private local attachment copies and stable
    // ingestion idempotency key to durable storage before returning localId.
    suspend fun persistIncomingShare(): String

    // Called only after a successful durable commit. Must not wait for AI/network.
    fun acknowledgeAndClose(localId: String)
}

/**
 * Persist visibility independently from workflow. Stable content notification ID,
 * one automatic notification, body -> details, only quick action -> Edit (수정하기).
 * Reconcile tombstones before displaying; updates must not restore dismissed items.
 */
interface NotificationContract {
    suspend fun reconcilePersistedState()
    suspend fun recordDismissal(contentId: String, generation: Long, expectedRevision: Long)
}
