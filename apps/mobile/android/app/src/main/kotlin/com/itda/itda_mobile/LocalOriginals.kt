package com.itda.itda_mobile

import java.io.File
import java.util.UUID

internal data class SavedPdf(val localId: UUID, val file: File, val filename: String)

internal class LocalOriginals(private val store: LocalShareStore, private val activeOwner: () -> UploadOwner?) {
    fun read(localId: UUID): Map<String, Any?> {
        val share = store.read(localId) ?: throw UploadProblem.permanent("local_share_missing")
        return describe(share)
    }

    fun readRegistered(ref: NoticeRef): Map<String, Any?>? {
        requireOwner(ref.owner)
        val share = store.acknowledged(ref) ?: return null
        return describe(share)
    }

    fun pdf(localId: UUID): SavedPdf = pdf(
        store.read(localId) ?: throw UploadProblem.permanent("local_share_missing"),
    )

    fun registeredPdf(ref: NoticeRef): SavedPdf {
        requireOwner(ref.owner)
        return pdf(store.acknowledged(ref) ?: throw UploadProblem.permanent("local_share_missing"))
    }

    private fun pdf(share: StoredShare): SavedPdf {
        val owner = share.progress.owner
        requireOwner(owner)
        val file = store.pdfFile(share) ?: throw UploadProblem.permanent("document_unavailable")
        val filename = share.receipt.getJSONObject("attachment").getString("filename")
        requireOwner(owner)
        return SavedPdf(share.localId, file, filename)
    }

    private fun describe(share: StoredShare): Map<String, Any?> {
        val owner = share.progress.owner
        requireOwner(owner)
        val receipt = share.receipt
        val original = mapOf(
            "input_type" to receipt.stringOrNull("input_type"),
            "source_text" to receipt.stringOrNull("source_text"),
            "source_url" to receipt.stringOrNull("source_url"),
            "subject" to receipt.shareSubject(),
            "filename" to receipt.optJSONObject("attachment")?.stringOrNull("filename"),
            // The image path remains inside the app process.
            "image_path" to store.imagePath(share),
        )
        requireOwner(owner)
        return original
    }

    private fun requireOwner(owner: UploadOwner?) {
        if (owner != null && owner != activeOwner()) throw UploadProblem.auth()
    }
}
