package com.itda.itda_mobile

import java.math.BigInteger
import java.time.Instant
import java.util.UUID
import org.json.JSONObject

internal data class SyncPosition(val cursor: String, val sequence: BigInteger?)

internal enum class SyncEntity(val wire: String) {
    CONTENT("content"), RECOMMENDATION("recommendation"), PREFERENCES("preferences"), NOTIFICATION("notification"),
}

internal data class SyncEvent(
    val sequence: BigInteger,
    val entity: SyncEntity,
    val entityId: UUID,
    val contentId: UUID?,
    val deleted: Boolean,
    val occurredAt: Instant,
) {
    companion object {
        fun fromWire(event: JSONObject, owner: UploadOwner): SyncEvent {
            val sequence = event.get("sequence")
            require(sequence is String && sequence.isNotEmpty() && sequence.all { it in '0'..'9' })
            val entity = SyncEntity.entries.firstOrNull { it.wire == event.getString("entity_type") }
            requireNotNull(entity)
            val id = event.uuid("entity_id")
            require(event.has("content_id"))
            val contentId = event.stringOrNull("content_id")?.let(::parseUuid)
            when (entity) {
                SyncEntity.PREFERENCES -> require(contentId == null && id == owner.userId)
                SyncEntity.CONTENT, SyncEntity.NOTIFICATION -> require(contentId == id)
                SyncEntity.RECOMMENDATION -> require(contentId != null)
            }
            val operation = event.getString("operation")
            require(operation == "upsert" || operation == "delete")
            return SyncEvent(
                sequence.toBigInteger(), entity, id, contentId, operation == "delete",
                Instant.parse(event.getString("occurred_at")),
            )
        }
    }
}

internal data class SyncPage(val events: List<SyncEvent>, val nextCursor: String, val hasMore: Boolean)

internal class LibrarySyncApi(private val api: AuthenticatedApi) {
    val catalog = CatalogApi(api)

    fun changes(owner: UploadOwner, cursor: String?): SyncPage {
        val query = mutableMapOf("limit" to "20")
        if (cursor != null) query["cursor"] = cursor
        val reply = api.request(owner, "GET", "v1/sync", query = query)
        if (reply.status == 400 && reply.errorCode() == "invalid_cursor") {
            throw UploadProblem.permanent("invalid_cursor")
        }
        val page = reply.expectJson(200)
        return decodeServer {
            val events = page.getJSONArray("events")
            val parsed = List(events.length()) { SyncEvent.fromWire(events.getJSONObject(it), owner) }
            require(parsed.zipWithNext().all { (previous, next) ->
                next.sequence > previous.sequence || next == previous
            })
            val next = page.get("next_cursor")
            val more = page.get("has_more")
            require(next is String && next.length <= 2048 && more is Boolean)
            SyncPage(parsed, next, more)
        }
    }

    fun preferences(owner: UploadOwner): String? {
        val reply = api.request(owner, "GET", "v1/preferences")
        if (reply.status == 404) return null
        val preferences = reply.expectJson(200)
        return decodeServer {
            require(preferences.uuid("user_id") == owner.userId)
            preferences.toString()
        }
    }
}
