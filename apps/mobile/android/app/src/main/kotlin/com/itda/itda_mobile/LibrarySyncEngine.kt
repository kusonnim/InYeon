package com.itda.itda_mobile

import java.util.UUID

internal class LibrarySyncEngine(
    private val owner: UploadOwner,
    private val cache: LibraryCache,
    private val api: LibrarySyncApi,
    private val verifyOwner: () -> Unit,
    private val acknowledged: () -> Set<UUID>,
    private val onApplied: (Set<UUID>) -> Unit = {},
) {
    fun synchronize() {
        verifyOwner()
        val saved = cache.position(owner)
        if (saved != null) {
            try {
                drain(saved) { before, after, events ->
                    val changes = resolve(events)
                    if (before != after || changes.isNotEmpty()) {
                        cache.applyPage(owner, checkNotNull(before), after, changes, verifyOwner)
                    }
                    if (changes.isNotEmpty()) onApplied(changes.contentIds())
                }
                return
            } catch (problem: UploadProblem) {
                if (problem.code != "invalid_cursor") throw problem
            }
        }
        try {
            bootstrap()
        } catch (problem: UploadProblem) {
            if (problem.code != "invalid_cursor") throw problem
            // A cursor can expire while the replacement snapshot is being assembled.
            throw UploadProblem.retry("sync_cursor_expired_during_bootstrap")
        }
    }

    private fun bootstrap() {
        val localIds = acknowledged()
        // Establish the feed boundary before traversing the newest-first catalog.
        // The boundary is provisional until the replacement and its catch-up are durable.
        val anchor = drain(null) { _, _, _ -> }
        val slot = cache.beginBootstrap(owner)
        stageCatalog(slot)
        cache.stage(owner, slot, listOf(LibraryChange.Preferences(api.preferences(owner))))
        val changed = localIds.toMutableSet()
        val caughtUp = drain(anchor) { _, _, events ->
            val changes = resolve(events)
            if (changes.isNotEmpty()) cache.stage(owner, slot, changes)
            changed.addAll(changes.contentIds())
        }
        cache.publishBootstrap(owner, slot, caughtUp, localIds, verifyOwner)
        if (changed.isNotEmpty()) onApplied(changed)
    }

    private fun stageCatalog(slot: Int) {
        var cursor: String? = null
        val seen = mutableSetOf<String>()
        do {
            verifyOwner()
            val page = api.catalog.list(owner, cursor)
            val (items, next) = decodeServer {
                val items = page.getJSONArray("items")
                val raw = page.get("next_cursor")
                require(raw == org.json.JSONObject.NULL || raw is String)
                val next = raw as? String
                require(next == null || (next.length <= 2048 && seen.add(next)))
                List(items.length()) { index ->
                    val item = items.getJSONObject(index)
                    LibraryChange.Content(item.uuid("id"), item)
                } to next
            }
            cache.stage(owner, slot, items)
            cursor = next
        } while (cursor != null)
    }

    private fun drain(
        start: SyncPosition?,
        apply: (SyncPosition?, SyncPosition, List<SyncEvent>) -> Unit,
    ): SyncPosition {
        var position = start
        val seen = mutableSetOf<String>()
        start?.let { seen.add(it.cursor) }
        do {
            verifyOwner()
            val page = api.changes(owner, position?.cursor)
            if (page.hasMore && !seen.add(page.nextCursor)) {
                throw UploadProblem.permanent("invalid_server_response")
            }
            val last = position?.sequence
            val events = page.events.filter { last == null || it.sequence > last }.distinctBy(SyncEvent::sequence)
            val next = SyncPosition(page.nextCursor, events.lastOrNull()?.sequence ?: last)
            apply(position, next, events)
            position = next
        } while (page.hasMore)
        return checkNotNull(position)
    }

    private fun resolve(events: List<SyncEvent>): List<LibraryChange> {
        val fetched = mutableMapOf<UUID, LibraryChange.Content>()
        return events.map { event ->
            when {
                event.entity == SyncEntity.PREFERENCES ->
                    LibraryChange.Preferences(if (event.deleted) null else api.preferences(owner))
                event.entity == SyncEntity.CONTENT && event.deleted -> {
                    fetched.remove(event.entityId)
                    LibraryChange.Content(event.entityId, null)
                }
                else -> {
                    val id = checkNotNull(event.contentId)
                    // Related entity events refresh the whole parent, including related deletions.
                    fetched.getOrPut(id) { LibraryChange.Content(id, api.catalog.content(owner, id)) }
                }
            }
        }
    }

    private fun List<LibraryChange>.contentIds(): Set<UUID> =
        filterIsInstance<LibraryChange.Content>().mapTo(mutableSetOf()) { it.id }
}
