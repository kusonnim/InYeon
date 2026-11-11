package com.itda.itda_mobile

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.FileNotFoundException
import java.util.UUID

/** Serves an individual original through a temporary, read-only Android URI grant. */
class SavedPdfProvider : ContentProvider() {
    override fun onCreate() = true

    override fun getType(uri: Uri) = PDF_TYPE

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw FileNotFoundException()
        val pdf = findPdf(uri) ?: throw FileNotFoundException()
        return ParcelFileDescriptor.open(pdf.file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? {
        val pdf = findPdf(uri) ?: return null
        val columns = (projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE))
            .filter { it == OpenableColumns.DISPLAY_NAME || it == OpenableColumns.SIZE }
        return MatrixCursor(columns.toTypedArray()).apply {
            addRow(columns.map { if (it == OpenableColumns.DISPLAY_NAME) pdf.filename else pdf.file.length() })
        }
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int =
        throw UnsupportedOperationException()
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int =
        throw UnsupportedOperationException()

    private fun findPdf(uri: Uri): SavedPdf? {
        val localId = uri.pathSegments.singleOrNull() ?: return null
        val context = context ?: return null
        return try {
            AndroidOutbox.get(context).originals.pdf(parseUuid(localId))
        } catch (_: Exception) {
            null
        }
    }

    internal companion object {
        private const val PDF_TYPE = "application/pdf"

        fun viewIntent(context: Context, localId: UUID): Intent {
            val uri = Uri.Builder().scheme("content")
                .authority("${context.packageName}.saved-pdf")
                .appendPath(localId.toString()).build()
            return Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, PDF_TYPE)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }
}
