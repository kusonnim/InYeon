package com.itda.itda_mobile

import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.time.Instant
import java.util.UUID
import okhttp3.HttpUrl
import org.json.JSONArray
import org.json.JSONObject

internal class UploadPipeline(
    private val config: UploadConfig,
    private val sessions: SupabaseSessions,
    private val http: UploadHttp,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val api = AuthenticatedApi(config, sessions, http)

    fun submit(share: StoredShare, checkpoint: (AssetProgress) -> Unit): UUID {
        val owner = share.progress.owner ?: throw UploadProblem.auth()
        sessions.requireOwner(owner)
        val source = share.receipt
        val type = source.getString("input_type")
        val assetId = when (type) {
            "text", "url" -> null
            "image", "document" -> uploadAsset(share, owner, checkpoint)
            else -> throw UploadProblem.permanent("invalid_local_receipt")
        }
        val text = source.stringOrNull("source_text")
        val url = source.stringOrNull("source_url")
        val body = JSONObject()
            .put("input_type", type)
            .put("source_text", text)
            .put("source_url", url)
            .put("asset_ids", JSONArray(listOfNotNull(assetId?.toString())))
        val reply = post(owner, source.uuid("client_event_id"), "v1/contents", body, 201)
        return decodeServer {
            require(reply.uuid("user_id") == owner.userId)
            require(reply.getString("input_type") == type && reply.has("source_text"))
            require(reply.stringOrNull("source_text") == text)
            val ids = reply.getJSONArray("asset_ids")
            require((0 until ids.length()).map { parseUuid(ids.getString(it)) } == listOfNotNull(assetId))
            reply.uuid("id")
        }
    }

    private fun uploadAsset(
        share: StoredShare,
        owner: UploadOwner,
        checkpoint: (AssetProgress) -> Unit,
    ): UUID {
        var progress = share.progress.asset ?: AssetProgress().also(checkpoint)
        if (progress.stage == AssetStage.VERIFIED) return checkNotNull(progress.assetId)
        val attachment = Attachment(share.receipt.getJSONObject("attachment"))

        repeat(2) { attempt ->
            try {
                if (progress.stage != AssetStage.COMPLETE) {
                    val capability = reserve(owner, progress, attachment)
                    val reserved = progress.copy(stage = AssetStage.PUT, assetId = capability.assetId)
                    if (reserved != progress) checkpoint(reserved)
                    progress = reserved
                    attachment.verifyLocal(share.sourceFile)
                    sessions.requireOwner(owner)
                    put(capability, share.sourceFile)
                    progress = progress.copy(stage = AssetStage.COMPLETE).also(checkpoint)
                }
                val assetId = checkNotNull(progress.assetId)
                val reply = post(
                    owner, progress.completionKey, "v1/assets/$assetId/complete", null, 200, assetOperation = true,
                )
                decodeServer {
                    require(reply.uuid("asset_id") == assetId && reply.getString("status") == "ready")
                    require(reply.getLong("size_bytes") == attachment.size)
                    require(reply.getString("media_type") == attachment.mediaType)
                    require(reply.getString("sha256") == attachment.sha256)
                }
                checkpoint(progress.copy(stage = AssetStage.VERIFIED))
                return assetId
            } catch (expired: ReservationExpired) {
                // A reservation can be replaced before content creation. Its two operation keys
                // belong to that reservation. The content key and original bytes stay fixed.
                if (attempt == 1 && expired.rejected) {
                    throw UploadProblem.permanent("upload_capability_rejected")
                }
                progress = AssetProgress().also(checkpoint)
            }
        }
        throw UploadProblem.retry("upload_expired")
    }

    private fun reserve(owner: UploadOwner, progress: AssetProgress, attachment: Attachment): Capability {
        val reply = post(
            owner, progress.reservationKey, "v1/assets/uploads", attachment.request(), 201, assetOperation = true,
        )
        return decodeServer {
            val id = reply.uuid("asset_id")
            require(progress.assetId == null || progress.assetId == id)
            val url = config.capability(reply.getString("upload_url"))
            val headers = reply.getJSONObject("upload_headers")
            val expiresAt = Instant.parse(reply.getString("expires_at")).toEpochMilli()
            Capability(id, url, headers.keys().asSequence().associateWith(headers::getString), expiresAt)
        }
    }

    private fun put(capability: Capability, file: File) {
        if (capability.expiresAtMs <= now()) throw ReservationExpired()
        val reply = http.put(capability.url, capability.headers, file)
        if (reply.status in 200..299 || reply.status == 409) return
        val storageError = reply.optionalJson()?.stringOrNull("error")
        // A prior PUT may have succeeded without a response. Completion always verifies the bytes.
        if (reply.status == 400 && storageError in setOf("Duplicate", "KeyAlreadyExists")) return
        if (storageError == "ExpiredToken" || capability.expiresAtMs <= now()) throw ReservationExpired()
        if (reply.status in setOf(401, 403) || storageError == "InvalidJWT") throw ReservationExpired(rejected = true)
        if (reply.retryable) throw UploadProblem.retry("storage_unavailable")
        throw UploadProblem.permanent("storage_rejected")
    }

    private fun post(
        owner: UploadOwner,
        key: UUID,
        path: String,
        body: JSONObject?,
        expectedStatus: Int,
        assetOperation: Boolean = false,
    ): JSONObject {
        val reply = api.request(owner, "POST", path, body, key)
        if (reply.status == expectedStatus) return reply.json()
        val code = reply.errorCode()
        if (assetOperation && reply.status == 409 && code == "upload_expired") throw ReservationExpired()
        if (reply.retryable) throw UploadProblem.retry("http_${reply.status}")
        throw UploadProblem.permanent(
            when {
                reply.status == 501 -> "backend_not_implemented"
                code == "idempotency_conflict" -> code
                reply.status in 200..299 -> "invalid_server_response"
                else -> "http_${reply.status}"
            },
        )
    }

    private class ReservationExpired(val rejected: Boolean = false) : Exception()

    private class Capability(
        val assetId: UUID,
        val url: HttpUrl,
        val headers: Map<String, String>,
        val expiresAtMs: Long,
    )

    private class Attachment(json: JSONObject) {
        private val filename = json.getString("filename")
        val mediaType = json.getString("media_type")
        val size = json.getLong("size_bytes")
        val sha256 = json.getString("sha256")

        fun request() = JSONObject().put("filename", filename).put("media_type", mediaType)
            .put("size_bytes", size).put("sha256", sha256)

        fun verifyLocal(file: File) {
            if (!file.isFile || file.length() != size) throw UploadProblem.permanent("local_source_unavailable")
            val digest = MessageDigest.getInstance("SHA-256")
            val actual = try {
                file.inputStream().use { input ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        val count = input.read(buffer)
                        if (count == -1) break
                        digest.update(buffer, 0, count)
                    }
                }
                digest.digest().toHex()
            } catch (_: IOException) {
                throw UploadProblem.permanent("local_source_unavailable")
            }
            if (actual != sha256) throw UploadProblem.permanent("local_source_changed")
        }
    }
}
