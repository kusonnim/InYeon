package com.itda.itda_mobile

import android.content.Intent
import java.util.UUID

/** Runs on the share I/O thread and returns only after the original and retry key commit. */
internal interface ShareIngestionContract {
    fun persistIncomingShare(
        localId: UUID,
        receivedAtMs: Long,
        intent: Intent,
        sourcePackage: String?,
    ): String
}
