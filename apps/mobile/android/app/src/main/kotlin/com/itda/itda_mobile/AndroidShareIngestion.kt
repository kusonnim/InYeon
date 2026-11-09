package com.itda.itda_mobile

import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import java.io.DataInputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.URI
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID
import org.json.JSONObject

internal class ShareRejected(val messageRes: Int) : Exception()

internal class AndroidShareIngestion(
    private val resolver: ContentResolver,
    private val store: LocalShareStore,
) : ShareIngestionContract {
    override fun persistIncomingShare(
        localId: UUID,
        receivedAtMs: Long,
        intent: Intent,
        sourcePackage: String?,
    ): String = store.persist(localId, receivedAtMs) { attachmentPath ->
        if (intent.action != Intent.ACTION_SEND) throw ShareRejected(R.string.share_unsupported)
        val mediaType = intent.type?.substringBefore(';')?.trim()?.lowercase(Locale.ROOT)
        val clip = intent.clipData
        if (clip != null && clip.itemCount != 1) throw ShareRejected(R.string.share_unsupported)
        val item = clip?.getItemAt(0)
        val text = (intent.getCharSequenceExtra(Intent.EXTRA_TEXT) ?: item?.text)?.toString()
        if (text != null && text.codePointCount(0, text.length) > MAX_TEXT_LENGTH) {
            throw ShareRejected(R.string.share_too_large)
        }
        val receipt = JSONObject()
            .put("source_text", text)
            .put("subject", intent.getCharSequenceExtra(Intent.EXTRA_SUBJECT)?.toString())
            .put("source_package", sourcePackage)
            .put("intent_media_type", intent.type)

        when {
            mediaType == "text/plain" -> {
                if (text.isNullOrBlank()) throw ShareRejected(R.string.share_empty)
                val url = sharedUrl(text)
                receipt.put("input_type", if (url == null) "text" else "url")
                    .put("source_url", url)
            }
            mediaType == "application/pdf" || mediaType?.startsWith("image/") == true -> {
                val uri = intent.streamUri() ?: item?.uri
                if (uri?.scheme != ContentResolver.SCHEME_CONTENT || uri.authority.isNullOrEmpty()) {
                    throw ShareRejected(R.string.share_unreadable)
                }
                val pdf = mediaType == "application/pdf"
                receipt.put("input_type", if (pdf) "document" else "image")
                    .put("attachment", copyAttachment(uri, attachmentPath, pdf))
            }
            else -> throw ShareRejected(R.string.share_unsupported)
        }
    }

    private fun copyAttachment(uri: Uri, destination: File, pdf: Boolean): JSONObject {
        val (displayName, reportedSize) = attachmentMetadata(uri)
        if (reportedSize != null && reportedSize > MAX_ASSET_BYTES) {
            throw ShareRejected(R.string.share_too_large)
        }
        val reportedType = runCatching { resolver.getType(uri) }.getOrNull()
        val descriptor = readSource { resolver.openAssetFileDescriptor(uri, "r") }
            ?: throw ShareRejected(R.string.share_unreadable)

        descriptor.use { source ->
            val size = source.length.takeIf { it >= 0 } ?: reportedSize
            if (size != null && size > MAX_ASSET_BYTES) throw ShareRejected(R.string.share_too_large)
            val input = DataInputStream(readSource { source.createInputStream() })
            input.use {
                val header = ByteArray(12)
                readSource { input.readFully(header) }
                val format = AttachmentFormat.detect(header)
                if (format == null || (format == AttachmentFormat.PDF) != pdf) {
                    throw ShareRejected(R.string.share_unsupported)
                }

                val digest = MessageDigest.getInstance("SHA-256")
                var copiedBytes = header.size.toLong()
                FileOutputStream(destination).use { output ->
                    output.write(header)
                    digest.update(header)
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        val count = readSource { input.read(buffer) }
                        if (count == -1) break
                        copiedBytes += count
                        if (copiedBytes > MAX_ASSET_BYTES) throw ShareRejected(R.string.share_too_large)
                        output.write(buffer, 0, count)
                        digest.update(buffer, 0, count)
                    }
                    readSource { source.parcelFileDescriptor.checkError() }
                    if (size != null && copiedBytes != size) {
                        throw ShareRejected(R.string.share_unreadable)
                    }
                    output.fd.sync()
                }

                return JSONObject()
                    .put("file_ref", LocalShareStore.ATTACHMENT_NAME)
                    .put("filename", displayName ?: "shared.${format.extension}")
                    .put("media_type", format.mediaType)
                    .put("size_bytes", copiedBytes)
                    .put("sha256", digest.digest().joinToString("") { "%02x".format(it) })
                    .put("reported_media_type", reportedType)
                    .put("provider_authority", uri.authority)
            }
        }
    }

    private fun attachmentMetadata(uri: Uri): Pair<String?, Long?> {
        // Some providers support opening a granted URI without exposing these columns.
        val columns = arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        return try {
            resolver.query(uri, columns, null, null, null)?.use { cursor ->
                if (!cursor.moveToFirst()) return@use null
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                val name = if (nameIndex >= 0) cursor.getString(nameIndex) else null
                val size = if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                    cursor.getLong(sizeIndex).takeIf { it >= 0 }
                } else null
                name?.substringAfterLast('/')?.substringAfterLast('\\')
                    ?.replace(controlCharacters, "")?.trim()?.take(255)?.takeIf { it.isNotEmpty() } to size
            } ?: (null to null)
        } catch (_: RuntimeException) {
            null to null
        }
    }

    private inline fun <T> readSource(read: () -> T): T = try {
        read()
    } catch (_: IOException) {
        throw ShareRejected(R.string.share_unreadable)
    } catch (_: RuntimeException) {
        throw ShareRejected(R.string.share_unreadable)
    }

    @Suppress("DEPRECATION")
    private fun Intent.streamUri(): Uri? = if (Build.VERSION.SDK_INT >= 33) {
        getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
    } else {
        getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
    }

    private fun sharedUrl(text: String): String? {
        val trimmed = text.trim()
        if (isHttpUrl(trimmed)) return trimmed
        return urlCandidates.findAll(text)
            .map { it.value.trimEnd('.', ',', ';', ')', ']', '}') }
            .filter(::isHttpUrl)
            .distinct()
            .singleOrNull()
    }

    private fun isHttpUrl(value: String): Boolean {
        if (value.length > 2083) return false
        val uri = try {
            URI(value)
        } catch (_: java.net.URISyntaxException) {
            return false
        }
        return (uri.scheme.equals("https", ignoreCase = true) ||
            uri.scheme.equals("http", ignoreCase = true)) && !Uri.parse(value).host.isNullOrBlank()
    }

    private enum class AttachmentFormat(val mediaType: String, val extension: String) {
        JPEG("image/jpeg", "jpg"),
        PNG("image/png", "png"),
        WEBP("image/webp", "webp"),
        PDF("application/pdf", "pdf");

        companion object {
            fun detect(header: ByteArray): AttachmentFormat? = when {
                header.startsWith(JPEG_SIGNATURE) -> JPEG
                header.startsWith(PNG_SIGNATURE) -> PNG
                header.startsWith(RIFF_SIGNATURE) && header.startsWith(WEBP_SIGNATURE, 8) -> WEBP
                header.startsWith(PDF_SIGNATURE) -> PDF
                else -> null
            }

            private fun ByteArray.startsWith(signature: ByteArray, offset: Int = 0) =
                signature.indices.all { this[offset + it] == signature[it] }

            private val JPEG_SIGNATURE = byteArrayOf(0xff.toByte(), 0xd8.toByte(), 0xff.toByte())
            private val PNG_SIGNATURE = byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)
            private val RIFF_SIGNATURE = "RIFF".toByteArray()
            private val WEBP_SIGNATURE = "WEBP".toByteArray()
            private val PDF_SIGNATURE = "%PDF-".toByteArray()
        }
    }

    private companion object {
        const val MAX_TEXT_LENGTH = 100_000
        const val MAX_ASSET_BYTES = 20L * 1024 * 1024
        val controlCharacters = Regex("\\p{Cntrl}")
        val urlCandidates = Regex("""https?://[^\s\p{Z}<>"\u0000-\u001f]+""", RegexOption.IGNORE_CASE)
    }
}
