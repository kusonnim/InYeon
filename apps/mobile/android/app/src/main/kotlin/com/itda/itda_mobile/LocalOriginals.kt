package com.itda.itda_mobile

import java.util.UUID

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
            // This path remains inside the app process. There is no exported file provider.
            "image_path" to store.imagePath(share),
        )
        requireOwner(owner)
        return original
    }

    private fun requireOwner(owner: UploadOwner?) {
        if (owner != null && owner != activeOwner()) throw UploadProblem.auth()
    }
}
