package com.itda.itda_mobile

import android.app.Activity
import android.content.Intent
import android.os.BadParcelableException
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.FrameLayout
import android.widget.ProgressBar
import android.widget.Toast
import java.util.UUID

class ShareReceiverActivity : Activity() {
    private lateinit var localId: UUID
    private var receivedAtMs = 0L
    private var sourcePackage: String? = null
    private var replacedIntent = false

    @Suppress("DEPRECATION")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val progress = ProgressBar(this).apply {
            contentDescription = getString(R.string.share_saving)
        }
        setContentView(FrameLayout(this).apply {
            addView(progress, FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.CENTER))
        })

        // Android restores the original Intent. Save a replacement only for singleTop redelivery.
        savedInstanceState?.getParcelable<Intent>(STATE_REPLACEMENT)?.let {
            replacedIntent = true
            setIntent(it)
        }
        localId = savedInstanceState?.getString(STATE_ID)?.let(UUID::fromString) ?: UUID.randomUUID()
        receivedAtMs = savedInstanceState?.getLong(STATE_TIME) ?: System.currentTimeMillis()
        sourcePackage = if (savedInstanceState == null) initialSourcePackage() else {
            savedInstanceState.getString(STATE_PACKAGE)
        }
        receive(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // This callback is a new send; recreation of an existing send reuses its saved ID.
        setIntent(intent)
        replacedIntent = true
        localId = UUID.randomUUID()
        receivedAtMs = System.currentTimeMillis()
        sourcePackage = callingPackage
        receive(intent)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putString(STATE_ID, localId.toString())
        outState.putLong(STATE_TIME, receivedAtMs)
        outState.putString(STATE_PACKAGE, sourcePackage)
        if (replacedIntent) outState.putParcelable(STATE_REPLACEMENT, intent)
    }

    private fun receive(incoming: Intent) {
        val id = localId
        val time = receivedAtMs
        val sender = sourcePackage
        val context = applicationContext
        shareIo.execute {
            val error = try {
                val ingestion: ShareIngestionContract =
                    AndroidShareIngestion(context.contentResolver, localShareStore(context))
                ingestion.persistIncomingShare(id, time, incoming, sender)
                null
            } catch (rejected: ShareRejected) {
                rejected.messageRes
            } catch (_: BadParcelableException) {
                R.string.share_unsupported
            } catch (_: Exception) {
                R.string.share_storage_failed
            }
            runOnUiThread {
                if (isFinishing || isDestroyed || localId != id) return@runOnUiThread
                if (error == null) {
                    acknowledgeAndClose()
                } else {
                    Toast.makeText(this, error, Toast.LENGTH_SHORT).show()
                    finish()
                }
            }
        }
    }

    private fun acknowledgeAndClose() {
        setResult(RESULT_OK)
        Toast.makeText(this, R.string.share_saved, Toast.LENGTH_SHORT).show()
        finish()
    }

    private fun initialSourcePackage(): String? =
        if (Build.VERSION.SDK_INT >= 34) launchedFromPackage ?: callingPackage else callingPackage

    private companion object {
        const val STATE_ID = "share_local_id"
        const val STATE_TIME = "share_received_at_ms"
        const val STATE_PACKAGE = "share_source_package"
        const val STATE_REPLACEMENT = "share_replacement_intent"
    }
}
