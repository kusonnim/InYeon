package com.itda.itda_mobile

import java.io.File
import java.io.IOException
import java.net.URI
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

internal enum class NoticeAnalysis(val wire: String, val message: Int) {
    PENDING("pending", R.string.notice_processing),
    PROCESSING("processing", R.string.notice_processing),
    COMPLETED("completed", R.string.notice_completed),
    PARTIAL("partial", R.string.notice_partial),
    FAILED("failed", R.string.notice_failed);

    companion object {
        fun parse(value: String) = entries.firstOrNull { it.wire == value }
            ?: throw IllegalArgumentException("Invalid analysis status")
    }
}

internal data class NoticeMetadata(
    val type: String?,
    val title: String?,
    val host: String?,
    val sourcePackage: String?,
) {
    fun toJson() = JSONObject().put("type", type).put("title", title)
        .put("host", host).put("source_package", sourcePackage)

    companion object {
        fun fromJson(json: JSONObject) = NoticeMetadata(
            json.stringOrNull("type"), json.stringOrNull("title"),
            json.stringOrNull("host"), json.stringOrNull("source_package"),
        )

        fun fromContent(json: JSONObject, receipt: JSONObject?) = NoticeMetadata(
            json.stringOrNull("input_type") ?: receipt?.stringOrNull("input_type"),
            safeTitle(json.stringOrNull("title")) ?: safeTitle(receipt?.stringOrNull("subject")),
            host(receipt?.stringOrNull("source_url") ?: json.stringOrNull("source_url")),
            receipt?.stringOrNull("source_package"),
        )

        private fun host(value: String?): String? {
            val url = value?.let { runCatching { URI(it) }.getOrNull() } ?: return null
            if (!url.scheme.equals("https", true) && !url.scheme.equals("http", true)) return null
            return url.host?.lowercase()?.takeIf { it.length <= 253 }
        }

        // Only explicit titles and share subjects are candidates. Source text, summaries,
        // filenames and full URLs do not belong on the Android notification surface.
        fun safeTitle(value: String?): String? {
            val title = value?.replace(Regex("[\\p{Cc}\\p{Cf}\\s]+"), " ")?.trim()
            if (title.isNullOrEmpty() || privateValue.containsMatchIn(title)) return null
            val count = title.codePointCount(0, title.length)
            return if (count <= 120) title else title.substring(0, title.offsetByCodePoints(0, 119)) + "…"
        }

        private val privateValue = Regex(
            """://|\bwww\.|\b(?:[a-z0-9-]+\.)+[a-z]{2,}/|\bbearer\s+|\b(?:sb_(?:secret|publishable)_|eyJ[a-z0-9_-]+\.|access_token\s*=|x-amz-|signature\s*=)""",
            RegexOption.IGNORE_CASE,
        )
    }
}

internal data class NoticeContent(
    val state: NoticeState,
    val analysis: NoticeAnalysis,
    val version: Long,
    val updatedAt: Instant,
    val metadata: NoticeMetadata? = null,
) {
    companion object {
        fun fromWire(json: JSONObject, ref: NoticeRef, receipt: JSONObject? = null): NoticeContent = decodeServer {
            require(json.uuid("id") == ref.contentId && json.uuid("user_id") == ref.owner.userId)
            NoticeContent(
                NoticeState.fromWire(json.getJSONObject("notification"), ref),
                NoticeAnalysis.parse(json.getString("analysis_status")),
                json.getLong("version").also { require(it >= 1) },
                Instant.parse(json.getString("updated_at")),
                NoticeMetadata.fromContent(json, receipt),
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

internal data class PostedNotice(val generation: Long, val analysis: NoticeAnalysis, val presentationKey: String? = null)

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
        if (fresher) return merged.copy(content = incoming.copy(state = merged.state))
        // Pre-A6.1 records can acquire metadata on an exact replay of the current version.
        if (content.metadata == null && incoming.version == content.version && incoming.updatedAt == content.updatedAt) {
            return merged.copy(content = merged.content.copy(metadata = incoming.metadata))
        }
        return merged
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
        .put("metadata", content.metadata?.toJson())
        .put("updated_at", content.updatedAt.toString()).put("dismissed_generation", dismissedGeneration)
        .put("event", event?.toJson()).put("posted_generation", posted?.generation)
        .put("posted_analysis", posted?.analysis?.wire).put("posted_presentation_key", posted?.presentationKey)
        .put("error", error)

    companion object {
        fun fromJson(json: JSONObject): NoticeRecord {
            val owner = UploadOwner(json.uuid("owner_id"), json.getString("realm"))
            return NoticeRecord(
                NoticeRef(owner, json.uuid("content_id")),
                NoticeContent(
                    NoticeState(json.getLong("generation"), json.getLong("revision"), json.getBoolean("remote_dismissed")),
                    NoticeAnalysis.parse(json.getString("analysis")), json.getLong("content_version"),
                    Instant.parse(json.getString("updated_at")),
                    json.optJSONObject("metadata")?.let(NoticeMetadata::fromJson),
                ),
                dismissedGeneration = json.optionalLong("dismissed_generation"),
                event = json.optJSONObject("event")?.let(NoticeEvent::fromJson),
                posted = json.optionalLong("posted_generation")?.let {
                    PostedNotice(it, NoticeAnalysis.parse(json.getString("posted_analysis")),
                        json.stringOrNull("posted_presentation_key"))
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
