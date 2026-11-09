package com.itda.itda_mobile

/**
 * Persist visibility independently from workflow. Stable content notification ID,
 * one automatic notification, body -> details, only quick action -> Edit (수정하기).
 * Reconcile tombstones before displaying; updates must not restore dismissed items.
 */
interface NotificationContract {
    suspend fun reconcilePersistedState()
    suspend fun recordDismissal(contentId: String, generation: Long, expectedRevision: Long)
}
