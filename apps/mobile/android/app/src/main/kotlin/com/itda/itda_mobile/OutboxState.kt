package com.itda.itda_mobile

import java.io.File
import java.util.UUID
import org.json.JSONObject

internal data class UploadOwner(val userId: UUID, val realm: String)

internal enum class UploadState(val wire: String) {
    PENDING("pending_upload"),
    UPLOADING("uploading"),
    RETRY_WAITING("retry_waiting"),
    AUTH_REQUIRED("authentication_required"),
    SYNCHRONIZED("synchronized"),
    PERMANENT_FAILURE("permanent_failure");

    val terminal: Boolean
        get() = this == SYNCHRONIZED || this == PERMANENT_FAILURE
}

internal enum class AssetStage { RESERVE, PUT, COMPLETE, VERIFIED }

internal data class AssetProgress(
    val reservationKey: UUID = UUID.randomUUID(),
    val completionKey: UUID = UUID.randomUUID(),
    val stage: AssetStage = AssetStage.RESERVE,
    val assetId: UUID? = null,
) {
    init {
        require((stage == AssetStage.RESERVE) == (assetId == null))
    }

    fun toJson() = JSONObject()
        .put("reservation_key", reservationKey.toString())
        .put("completion_key", completionKey.toString())
        .put("stage", stage.name)
        .put("asset_id", assetId?.toString())

    companion object {
        fun fromJson(json: JSONObject) = AssetProgress(
            reservationKey = json.uuid("reservation_key"),
            completionKey = json.uuid("completion_key"),
            stage = AssetStage.valueOf(json.getString("stage")),
            assetId = json.stringOrNull("asset_id")?.let(::parseUuid),
        )
    }
}

internal data class UploadProgress(
    val owner: UploadOwner? = null,
    val state: UploadState = if (owner == null) UploadState.AUTH_REQUIRED else UploadState.PENDING,
    val asset: AssetProgress? = null,
    val serverContentId: UUID? = null,
    val lastError: String? = null,
) {
    init {
        require((state == UploadState.SYNCHRONIZED) == (serverContentId != null))
        require(owner != null || state == UploadState.AUTH_REQUIRED)
    }

    fun toJson() = JSONObject()
        .put("owner_id", owner?.userId?.toString())
        .put("realm", owner?.realm)
        .put("upload_state", state.wire)
        .put("asset", asset?.toJson())
        .put("server_content_id", serverContentId?.toString())
        .put("last_error", lastError)

    companion object {
        fun fromJson(json: JSONObject) = UploadProgress(
            owner = json.stringOrNull("owner_id")?.let {
                UploadOwner(parseUuid(it), json.getString("realm"))
            },
            state = UploadState.entries.single { it.wire == json.getString("upload_state") },
            asset = json.optJSONObject("asset")?.let(AssetProgress::fromJson),
            serverContentId = json.stringOrNull("server_content_id")?.let(::parseUuid),
            lastError = json.stringOrNull("last_error"),
        )
    }
}

internal data class StoredShare(
    val localId: UUID,
    val receipt: JSONObject,
    val sourceFile: File,
    val progress: UploadProgress,
) {
    fun summary(activeOwner: UploadOwner?): Map<String, Any?> {
        val visible = progress.owner == null || progress.owner == activeOwner
        val sourceUrl = if (visible) receipt.stringOrNull("source_url") else null
        val label = if (visible) {
            receipt.optJSONObject("attachment")?.getString("filename")
                ?: receipt.optString("source_url").ifEmpty { receipt.getString("source_text").trim() }
        } else {
            "Share for another account"
        }
        val state = if (visible) progress.state else UploadState.AUTH_REQUIRED
        return mapOf(
            "local_id" to localId.toString(),
            "input_type" to if (visible) receipt.getString("input_type") else null,
            "label" to label.take(200),
            "source_url" to sourceUrl,
            "subject" to if (visible) receipt.shareSubject() else null,
            "link_text" to sourceUrl?.let { receipt.stringOrNull("source_text")?.takeIf { it.length <= 4096 } },
            "received_at_ms" to receipt.getLong("received_at_ms"),
            "upload_state" to state.wire,
            "can_assign" to (progress.owner == null && activeOwner != null),
            "last_error" to if (visible) progress.lastError else null,
            "server_content_id" to if (visible) progress.serverContentId?.toString() else null,
        )
    }
}

internal fun JSONObject.shareSubject(): String? =
    stringOrNull("subject")?.trim()?.take(500)?.takeIf { it.isNotEmpty() }

internal fun JSONObject.stringOrNull(key: String): String? = if (isNull(key)) null else getString(key)

internal fun JSONObject.uuid(key: String): UUID = parseUuid(getString(key))

internal fun parseUuid(value: String): UUID = UUID.fromString(value).also {
    require(it.toString().equals(value, ignoreCase = true))
}
