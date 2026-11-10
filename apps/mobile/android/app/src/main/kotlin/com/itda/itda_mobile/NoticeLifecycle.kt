package com.itda.itda_mobile

internal interface NoticeSurface {
    fun presentationLanguage(): String? = null
    fun canPost(): Boolean
    fun activeGeneration(ref: NoticeRef): Long?
    fun post(record: NoticeRecord, update: Boolean)
    fun cancel(ref: NoticeRef)
    fun hideOtherOwners(owner: UploadOwner?)
}

internal class NoticeLifecycle(
    private val store: NoticeStore,
    private val surface: NoticeSurface,
    private val activeOwner: () -> UploadOwner?,
    private val onChange: () -> Unit = {},
) {
    private val lock = Any()

    fun read(ref: NoticeRef): NoticeRecord? = synchronized(lock) { store.read(ref) }

    fun observe(ref: NoticeRef, content: NoticeContent) = synchronized(lock) {
        if (activeOwner() != ref.owner) return@synchronized
        val old = store.read(ref)
        saveAndRender(old, old?.mergeContent(content) ?: NoticeRecord(ref, content))
    }

    fun dismiss(ref: NoticeRef, generation: Long): Boolean = synchronized(lock) {
        val old = store.read(ref) ?: return@synchronized false
        if (old.state.generation != generation || old.posted?.generation != generation || old.suppressed) {
            return@synchronized false
        }
        val event = NoticeEvent(NoticeOperation.DISMISS, generation, old.state.revision)
        // Android already removed the card. Commit suppression before any network work.
        saveAndRender(old, old.copy(dismissedGeneration = generation, event = event, error = null))
        true
    }

    fun requestRestore(ref: NoticeRef): Boolean = synchronized(lock) {
        if (activeOwner() != ref.owner) throw UploadProblem.auth()
        val old = store.read(ref) ?: return@synchronized false
        if (!old.canRestore) return@synchronized false
        val event = NoticeEvent(NoticeOperation.RESTORE, old.state.generation, old.state.revision)
        saveAndRender(old, old.copy(event = event, error = null))
        true
    }

    fun acknowledge(ref: NoticeRef, event: NoticeEvent, authoritative: NoticeContent) = synchronized(lock) {
        if (activeOwner() != ref.owner) return@synchronized
        val old = store.read(ref) ?: return@synchronized
        val merged = old.mergeContent(authoritative)
        val next = if (merged.event?.key == event.key && event.operation == NoticeOperation.RESTORE) {
            merged.copy(event = null, error = null)
        } else {
            merged
        }
        saveAndRender(old, next)
    }

    // A version conflict is definitive. Only a dismissal can rebase onto a newer
    // revision of the same generation. Restoration requires another user action.
    fun resolveConflict(ref: NoticeRef, event: NoticeEvent, authoritative: NoticeContent): Boolean =
        synchronized(lock) {
            if (activeOwner() != ref.owner) return@synchronized false
            val old = store.read(ref) ?: return@synchronized false
            val merged = old.mergeContent(authoritative)
            if (merged.event?.key != event.key) {
                saveAndRender(old, merged)
                return@synchronized false
            }
            val canRebase = event.operation == NoticeOperation.DISMISS &&
                merged.state.generation == event.generation && merged.state.revision > event.revision
            if (canRebase) {
                val revised = NoticeEvent(NoticeOperation.DISMISS, event.generation, merged.state.revision)
                saveAndRender(old, merged.copy(event = revised, error = null))
                return@synchronized true
            }
            saveAndRender(old, failed(merged, event, "notification_conflict"))
            false
        }

    fun reject(ref: NoticeRef, event: NoticeEvent, code: String) = synchronized(lock) {
        if (activeOwner() != ref.owner) return@synchronized
        val old = store.read(ref) ?: return@synchronized
        if (old.event?.key == event.key) saveAndRender(old, failed(old, event, code))
    }

    fun hideInactiveAccounts() = synchronized(lock) { surface.hideOtherOwners(activeOwner()) }

    fun refreshPresentation(ref: NoticeRef) = synchronized(lock) {
        val record = store.read(ref) ?: return@synchronized
        if (activeOwner() != ref.owner || record.posted?.generation != record.state.generation ||
            surface.activeGeneration(ref) != record.state.generation
        ) return@synchronized
        saveAndRender(record, record)
    }

    private fun failed(record: NoticeRecord, event: NoticeEvent, code: String) =
        record.copy(event = event.takeIf { it.operation == NoticeOperation.DISMISS }?.copy(blocked = true), error = code)

    private fun saveAndRender(old: NoticeRecord?, record: NoticeRecord) {
        if (old != record) store.write(record)
        if (activeOwner() != record.ref.owner || record.suppressed) {
            surface.cancel(record.ref)
        } else if (surface.canPost()) {
            val language = surface.presentationLanguage()
            val metadata = record.content.metadata
            val key = if (language != null || metadata != null) {
                sha256((language.orEmpty() + "/" + metadata?.toJson()).toByteArray())
            } else null
            val shown = PostedNotice(record.state.generation, record.content.analysis, key)
            val issued = record.posted
            val fresh = issued == null || shown.generation > issued.generation
            val update = issued?.generation == shown.generation && issued != shown &&
                surface.activeGeneration(record.ref) == shown.generation
            if (fresh || update) {
                // Persist the one-time issuance before notifying. A missing card from an
                // issued generation is never posted again by refresh or process recovery.
                store.write(record.copy(posted = shown))
                if (activeOwner() == record.ref.owner) surface.post(record, update)
            }
        }
        if (old != record) onChange()
    }
}
