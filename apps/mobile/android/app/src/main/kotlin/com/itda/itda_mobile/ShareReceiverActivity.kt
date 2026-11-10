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
    private var restoredDelivery = false
    private var restoredOwner: UploadOwner? = null
    @Volatile private var resolvedOwner: Pair<UUID, UploadOwner>? = null

    @Suppress("DEPRECATION")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val progress = ProgressBar(this).apply {
            contentDescription = AppLanguage.resources(this@ShareReceiverActivity).getString(R.string.share_saving)
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
        restoredDelivery = savedInstanceState != null
        restoredOwner = savedInstanceState?.getString(STATE_OWNER)?.let { ownerId ->
            savedInstanceState.getString(STATE_REALM)?.let { realm -> UploadOwner(parseUuid(ownerId), realm) }
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
        restoredDelivery = false
        restoredOwner = null
        receive(intent)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putString(STATE_ID, localId.toString())
        outState.putLong(STATE_TIME, receivedAtMs)
        outState.putString(STATE_PACKAGE, sourcePackage)
        if (replacedIntent) outState.putParcelable(STATE_REPLACEMENT, intent)
        resolvedOwner?.takeIf { it.first == localId }?.second?.let { owner ->
            outState.putString(STATE_OWNER, owner.userId.toString())
            outState.putString(STATE_REALM, owner.realm)
        }
    }

    private fun receive(incoming: Intent) {
        val id = localId
        val time = receivedAtMs
        val sender = sourcePackage
        val isRestored = restoredDelivery
        val previousOwner = restoredOwner
        val context = applicationContext
        shareIo.execute {
            val error = try {
                val outbox = AndroidOutbox.get(context)
                // A replay with unknown prior ownership waits for explicit assignment.
                val owner = if (isRestored) previousOwner else outbox.activeOwner()
                resolvedOwner = owner?.let { id to it }
                val ingestion: ShareIngestionContract = AndroidShareIngestion(
                    context.contentResolver, outbox.store, owner,
                ) { if (owner != null) outbox.scheduleReceipt(id) }
                ingestion.persistIncomingShare(id, time, incoming, sender)
                outbox.receiptSaved()
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
                    toast(error)
                    finish()
                }
            }
        }
    }

    private fun acknowledgeAndClose() {
        setResult(RESULT_OK)
        toast(R.string.share_saved)
        finish()
    }

    private fun toast(message: Int) {
        Toast.makeText(this, AppLanguage.resources(this).getString(message), Toast.LENGTH_SHORT).show()
    }

    private fun initialSourcePackage(): String? =
        if (Build.VERSION.SDK_INT >= 34) launchedFromPackage ?: callingPackage else callingPackage

    private companion object {
        const val STATE_ID = "share_local_id"
        const val STATE_TIME = "share_received_at_ms"
        const val STATE_PACKAGE = "share_source_package"
        const val STATE_REPLACEMENT = "share_replacement_intent"
        const val STATE_OWNER = "share_owner_id"
        const val STATE_REALM = "share_owner_realm"
    }
}
