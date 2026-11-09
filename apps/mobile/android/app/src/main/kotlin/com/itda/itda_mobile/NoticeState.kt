package com.itda.itda_mobile

import java.io.File
import java.io.IOException
import java.time.Instant
import java.util.UUID
import org.json.JSONObject

internal data class NoticeRef(val owner: UploadOwner, val contentId: UUID) {
    val tag: String get() = ownerPrefix(owner) + contentId

    fun toMap() = mapOf("owner_id" to owner.userId.toString(), "realm" to owner.realm, "content_id" to contentId.toString())

    companion object {
        const val TAG_PREFIX = "itda-notice:"

        fun ownerPrefix(owner: UploadOwner) =
            TAG_PREFIX + sha256("${owner.realm}/${owner.userId}".toByteArray()) + ":"
    }
}

internal data class NoticeState(val generation: Long, val revision: Long, val dismissed: Boolean) {
    init {
        require(generation >= 1 && revision >= 1)
    }

    fun merge(incoming: NoticeState): NoticeState = when {
        incoming.generation > generation -> incoming
        incoming.generation < generation || incoming.revision <= revision -> this
        dismissed && !incoming.dismissed -> this
        else -> incoming
    }

    companion object {
        fun fromWire(json: JSONObject, ref: NoticeRef): NoticeState {
            require(json.uuid("content_id") == ref.contentId)
            val visibility = json.getString("visibility")
            require(visibility in setOf("active", "dismissed"))
            return NoticeState(json.getLong("generation"), json.getLong("revision"), visibility == "dismissed")
        }
    }
}

internal enum class NoticeAnalysis(val wire: String, val text: String) {
    PENDING("pending", "Saved. Analysis pending."),
    PROCESSING("processing", "Analysis in progress."),
    COMPLETED("completed", "Analysis is ready."),
    PARTIAL("partial", "Partial analysis is ready."),
    FAILED("failed", "Saved. Analysis could not finish.");

    companion object {
        fun parse(value: String) = entries.firstOrNull { it.wire == value }
            ?: throw IllegalArgumentException("Invalid analysis status")
    }
}

internal data class NoticeContent(
    val state: NoticeState,
    val analysis: NoticeAnalysis,
    val version: Long,
    val updatedAt: Instant,
) {
    companion object {
        fun fromWire(json: JSONObject, ref: NoticeRef): NoticeContent = decodeServer {
            require(json.uuid("id") == ref.contentId && json.uuid("user_id") == ref.owner.userId)
            NoticeContent(
                NoticeState.fromWire(json.getJSONObject("notification"), ref),
                NoticeAnalysis.parse(json.getString("analysis_status")),
                json.getLong("version").also { require(it >= 1) },
                Instant.parse(json.getString("updated_at")),
            )
        }
    }
}

internal enum class NoticeOperation { DISMISS, RESTORE }

internal data class NoticeEvent(
    val operation: NoticeOperation,
    val generation: Long,
    val revision: Long,
    val key: UUID = UUID.randomUUID(),
    val blocked: Boolean = false,
) {
    fun toJson() = JSONObject().put("operation", operation.name)
        .put("generation", generation).put("revision", revision)
        .put("key", key.toString()).put("blocked", blocked)

    companion object {
        fun fromJson(json: JSONObject) = NoticeEvent(
            NoticeOperation.valueOf(json.getString("operation")),
            json.getLong("generation"), json.getLong("revision"), json.uuid("key"), json.getBoolean("blocked"),
        )
    }
}

internal data class PostedNotice(val generation: Long, val analysis: NoticeAnalysis)

internal data class NoticeRecord(
    val ref: NoticeRef,
    val content: NoticeContent,
    val dismissedGeneration: Long? = null,
    val event: NoticeEvent? = null,
    val posted: PostedNotice? = null,
    val error: String? = null,
) {
    val state get() = content.state
    val suppressed get() = state.dismissed || dismissedGeneration == state.generation
    val canRestore get() = state.dismissed && event == null

    fun mergeState(incoming: NoticeState): NoticeRecord {
        val next = state.merge(incoming)
        val pending = event?.takeUnless {
            next.generation > it.generation || (it.operation == NoticeOperation.DISMISS && next.dismissed)
        }
        return copy(content = content.copy(state = next), event = pending, error = if (pending != event) null else error)
    }

    fun mergeContent(incoming: NoticeContent): NoticeRecord {
        val merged = mergeState(incoming.state)
        val fresher = incoming.version > content.version ||
            (incoming.version == content.version && incoming.updatedAt > content.updatedAt)
        return if (fresher) merged.copy(content = incoming.copy(state = merged.state)) else merged
    }

    fun summary(): Map<String, Any?> = mapOf(
        "can_restore" to canRestore,
        "dismissed" to suppressed,
        "pending" to event?.takeUnless { it.blocked }?.operation?.name?.lowercase(),
        "error" to error,
    )

    fun toJson() = JSONObject(ref.toMap()).put("generation", state.generation)
        .put("revision", state.revision).put("remote_dismissed", state.dismissed)
        .put("analysis", content.analysis.wire).put("content_version", content.version)
        .put("updated_at", content.updatedAt.toString()).put("dismissed_generation", dismissedGeneration)
        .put("event", event?.toJson()).put("posted_generation", posted?.generation)
        .put("posted_analysis", posted?.analysis?.wire).put("error", error)

    companion object {
        fun fromJson(json: JSONObject): NoticeRecord {
            val owner = UploadOwner(json.uuid("owner_id"), json.getString("realm"))
            return NoticeRecord(
                NoticeRef(owner, json.uuid("content_id")),
                NoticeContent(
                    NoticeState(json.getLong("generation"), json.getLong("revision"), json.getBoolean("remote_dismissed")),
                    NoticeAnalysis.parse(json.getString("analysis")), json.getLong("content_version"),
                    Instant.parse(json.getString("updated_at")),
                ),
                dismissedGeneration = json.optionalLong("dismissed_generation"),
                event = json.optJSONObject("event")?.let(NoticeEvent::fromJson),
                posted = json.optionalLong("posted_generation")?.let {
                    PostedNotice(it, NoticeAnalysis.parse(json.getString("posted_analysis")))
                },
                error = json.stringOrNull("error"),
            )
        }

        private fun JSONObject.optionalLong(key: String) = if (isNull(key)) null else getLong(key)
    }
}

/** Owned by the lifecycle lock. The record contains no source payload or credentials. */
internal class NoticeStore(private val root: File) {
    fun read(ref: NoticeRef): NoticeRecord? {
        val file = fileFor(ref)
        if (!file.exists()) return null
        val record = NoticeRecord.fromJson(JSONObject(file.readText()))
        check(record.ref == ref)
        return record
    }

    fun write(record: NoticeRecord) {
        if (!root.isDirectory) {
            if (!root.mkdir()) throw IOException("Could not create notification store")
            syncDirectory(checkNotNull(root.parentFile))
        }
        replaceDurably(fileFor(record.ref), record.toJson().toString().toByteArray())
    }

    private fun fileFor(ref: NoticeRef) = File(root, sha256(ref.tag.toByteArray()) + ".json")
}
