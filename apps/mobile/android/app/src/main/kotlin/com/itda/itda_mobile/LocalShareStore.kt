package com.itda.itda_mobile

import android.content.Context
import android.graphics.BitmapFactory
import android.system.Os
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.Executors
import org.json.JSONObject

// Preserve UI event ordering for receiver and account changes. Workers use the store lock.
internal val shareIo = Executors.newSingleThreadExecutor()

internal fun localShareStore(context: Context) =
    LocalShareStore(File(context.noBackupFilesDir, "share-inbox-v1"))

internal class LocalShareStore(private val root: File) {
    // The source writer receives a fixed path inside staging, never a provider filename.
    fun persist(
        localId: UUID,
        receivedAtMs: Long,
        owner: UploadOwner? = null,
        beforePublish: () -> Unit = {},
        writeSource: (File) -> JSONObject,
    ): String = synchronized(storeLock) {
        if (!root.isDirectory && !root.mkdir()) throw IOException("Could not create share inbox")
        val id = localId.toString()
        val committed = File(root, id)
        cleanStaging()
        if (committed.exists()) {
            val existing = readReceipt(committed)
            val attachment = existing.optJSONObject("attachment")
            if (attachment != null) {
                val file = File(committed, ATTACHMENT_NAME)
                if (!file.isFile || file.length() != attachment.getLong("size_bytes")) {
                    throw IOException("Missing or incomplete share attachment")
                }
            }
            syncInbox()
            return@synchronized id
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
            writeSynced(File(staging, RECEIPT_NAME), receipt.toString().toByteArray())
            if (owner != null) {
                val progress = UploadProgress(owner)
                writeSynced(File(staging, OUTBOX_NAME), progress.toJson().toString().toByteArray())
            }

            // One same-filesystem rename publishes the synced bytes and outbox entry together.
            syncDirectory(staging)
            beforePublish()
            Os.rename(staging.path, committed.path)
            syncInbox()
            id
        } finally {
            staging.deleteRecursively()
        }
    }

    fun listShares(activeOwner: UploadOwner? = null): List<Map<String, Any?>> = entries()
        .sortedWith(compareByDescending<StoredShare> { it.receipt.getLong("received_at_ms") }.thenBy { it.localId })
        .map { it.summary(activeOwner) }

    fun acknowledged(ref: NoticeRef): StoredShare? = entries().firstOrNull {
        it.progress.owner == ref.owner && it.progress.serverContentId == ref.contentId
    }

    fun imagePath(share: StoredShare): String? {
        if (share.receipt.stringOrNull("input_type") != "image") return null
        val attachment = share.receipt.optJSONObject("attachment") ?: return null
        return runCatching {
            val mediaType = attachment.getString("media_type")
            if (mediaType !in imageTypes || attachment.getString("file_ref") != ATTACHMENT_NAME) return null
            val expected = File(File(root.canonicalFile, share.localId.toString()), ATTACHMENT_NAME)
            val file = share.sourceFile.canonicalFile
            if (file != expected || !file.isFile || file.length() !in 1..MAX_IMAGE_BYTES ||
                file.length() != attachment.getLong("size_bytes")
            ) return null
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.path, bounds)
            if (bounds.outMimeType != mediaType || bounds.outWidth <= 0 || bounds.outHeight <= 0 ||
                bounds.outWidth.toLong() * bounds.outHeight > MAX_IMAGE_PIXELS ||
                sha256(file) != attachment.getString("sha256")
            ) return null
            file.path
        }.getOrNull()
    }

    fun entries(): List<StoredShare> = synchronized(storeLock) {
        if (!root.exists()) return@synchronized emptyList()
        val entries = cleanStaging()
        // A process may have died after rename but before syncing the parent directories.
        syncInbox()
        entries.map { directory ->
            syncDirectory(directory)
            readShare(directory)
        }
    }

    fun read(localId: UUID): StoredShare? = synchronized(storeLock) {
        val directory = File(root, localId.toString())
        if (!directory.isDirectory) return@synchronized null
        // Recover a directory or sidecar published immediately before a process died.
        syncInbox()
        syncDirectory(directory)
        readShare(directory)
    }

    fun updateProgress(localId: UUID, update: (UploadProgress) -> UploadProgress): UploadProgress =
        synchronized(storeLock) {
            val directory = File(root, localId.toString())
            if (!directory.isDirectory) throw IOException("Missing local share")
            val file = File(directory, OUTBOX_NAME)
            val previous = readProgress(file)
            val progress = update(previous)
            if (progress != previous) {
                replaceDurably(file, progress.toJson().toString().toByteArray())
            }
            progress
        }

    private fun readShare(directory: File) = StoredShare(
        localId = parseUuid(directory.name),
        receipt = readReceipt(directory),
        sourceFile = File(directory, ATTACHMENT_NAME),
        progress = readProgress(File(directory, OUTBOX_NAME)),
    )

    private fun readProgress(file: File): UploadProgress {
        if (!file.exists()) return UploadProgress()
        return UploadProgress.fromJson(JSONObject(file.readText()))
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
        return receipt
    }

    private fun syncInbox() {
        syncDirectory(root)
        syncDirectory(checkNotNull(root.parentFile))
    }

    companion object {
        private val storeLock = Any()
        private const val STAGING_PREFIX = ".incoming-"
        private const val RECEIPT_NAME = "receipt.json"
        private const val OUTBOX_NAME = "outbox.json"
        internal const val ATTACHMENT_NAME = "source"
        private const val MAX_IMAGE_BYTES = 20L * 1024 * 1024
        private const val MAX_IMAGE_PIXELS = 64_000_000L
        private val imageTypes = setOf("image/jpeg", "image/png", "image/webp")
    }
}
