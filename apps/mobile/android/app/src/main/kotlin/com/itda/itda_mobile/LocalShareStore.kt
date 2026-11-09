package com.itda.itda_mobile

import android.content.Context
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.UUID
import java.util.concurrent.Executors
import org.json.JSONObject

// Both activities run in the same process. Serialize copies, reads and staging cleanup.
internal val shareIo = Executors.newSingleThreadExecutor()

internal fun localShareStore(context: Context) =
    LocalShareStore(File(context.noBackupFilesDir, "share-inbox-v1"))

internal class LocalShareStore(private val root: File) {
    // The source writer receives a fixed path inside staging, never a provider filename.
    fun persist(localId: UUID, receivedAtMs: Long, writeSource: (File) -> JSONObject): String {
        if (!root.isDirectory && !root.mkdir()) throw IOException("Could not create share inbox")
        val id = localId.toString()
        val committed = File(root, id)
        cleanStaging()
        if (committed.exists()) {
            readReceipt(committed)
            syncInbox()
            return id
        }

        val staging = File(root, "$STAGING_PREFIX$id")
        if (!staging.mkdir()) throw IOException("Could not stage share")
        try {
            val receipt = writeSource(File(staging, ATTACHMENT_NAME))
                .put("local_id", id)
                .put("client_event_id", UUID.randomUUID().toString())
                .put("received_at_ms", receivedAtMs)
                .put("upload_state", "pending_upload")
                .put("last_error", JSONObject.NULL)
            FileOutputStream(File(staging, RECEIPT_NAME)).use { output ->
                output.write(receipt.toString().toByteArray(Charsets.UTF_8))
                output.fd.sync()
            }

            // One same-filesystem rename publishes the synced bytes and outbox entry together.
            syncDirectory(staging)
            Os.rename(staging.path, committed.path)
            syncInbox()
            return id
        } finally {
            staging.deleteRecursively()
        }
    }

    fun listPending(): List<Map<String, Any>> {
        if (!root.exists()) return emptyList()
        val entries = cleanStaging()
        // A process may have died after rename but before syncing the parent directories.
        syncInbox()
        return entries.map { directory ->
            val receipt = readReceipt(directory)
            val attachment = receipt.optJSONObject("attachment")
            val label = attachment?.getString("filename")
                ?: receipt.optString("source_url").ifEmpty { receipt.getString("source_text").trim() }
            PendingShare(
                receipt.getString("local_id"),
                receipt.getString("input_type"),
                label.take(200),
                receipt.getLong("received_at_ms"),
                receipt.getString("upload_state"),
            )
        }.sortedWith(compareByDescending<PendingShare> { it.receivedAtMs }.thenBy { it.localId })
            .map { it.toChannelMap() }
    }

    private fun cleanStaging(): List<File> {
        val entries = root.listFiles() ?: throw IOException("Could not read share inbox")
        return entries.filter { entry ->
            if (!entry.name.startsWith(STAGING_PREFIX)) {
                true
            } else {
                if (!entry.deleteRecursively()) throw IOException("Could not clean interrupted share")
                false
            }
        }
    }

    private fun readReceipt(directory: File): JSONObject {
        val receipt = JSONObject(File(directory, RECEIPT_NAME).readText())
        if (receipt.getString("local_id") != directory.name) {
            throw IOException("Share receipt ID does not match its directory")
        }
        val attachment = receipt.optJSONObject("attachment")
        if (attachment != null) {
            val file = File(directory, ATTACHMENT_NAME)
            if (!file.isFile || file.length() != attachment.getLong("size_bytes")) {
                throw IOException("Missing or incomplete share attachment")
            }
        }
        return receipt
    }

    private fun syncInbox() {
        syncDirectory(root)
        syncDirectory(checkNotNull(root.parentFile))
    }

    private fun syncDirectory(directory: File) {
        val fd = Os.open(directory.path, OsConstants.O_RDONLY, 0)
        try {
            Os.fsync(fd)
        } finally {
            Os.close(fd)
        }
    }

    private data class PendingShare(
        val localId: String,
        val inputType: String,
        val label: String,
        val receivedAtMs: Long,
        val uploadState: String,
    ) {
        fun toChannelMap() = mapOf(
            "local_id" to localId,
            "input_type" to inputType,
            "label" to label,
            "received_at_ms" to receivedAtMs,
            "upload_state" to uploadState,
        )
    }

    companion object {
        private const val STAGING_PREFIX = ".incoming-"
        private const val RECEIPT_NAME = "receipt.json"
        internal const val ATTACHMENT_NAME = "source"
    }
}
