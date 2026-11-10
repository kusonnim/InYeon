package com.itda.itda_mobile

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.workDataOf
import java.io.File
import java.util.UUID
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.TimeUnit.SECONDS

internal class AndroidOutbox private constructor(context: Context) {
    private val config = UploadConfig.installed()
    private val vault = SessionVault(File(context.noBackupFilesDir, "supabase-session-v1"))
    private val sessions = config?.let { SupabaseSessions(it, vault) }
    private val listeners = CopyOnWriteArraySet<() -> Unit>()
    private val workManager by lazy { WorkManager.getInstance(context) }

    val store = localShareStore(context)
    val originals = LocalOriginals(store, ::activeOwner)
    val notices by lazy { AndroidNotifications(context, config, sessions, store, ::changed) }
    val library by lazy {
        config?.let { AndroidLibrarySync(context, it, checkNotNull(sessions), store, ::changed) { owner, ids ->
            notices.refreshSynced(owner, ids)
        } }
    }
    val processor = UploadProcessor(store, config, sessions, ::changed) { ref ->
        notices.registered(ref)
        library?.request(ref.owner, wait = true)
    }

    fun activeOwner(): UploadOwner? = sessions?.current()?.owner

    fun snapshotForSignIn(): SessionSnapshot = vault.snapshot()

    fun requestSession(email: String, password: String): SupabaseSession =
        (sessions ?: throw UploadProblem.auth("upload_not_configured")).signIn(email, password)

    fun installSession(snapshot: SessionSnapshot, session: SupabaseSession) {
        if (!vault.replaceIfCurrent(snapshot, session)) throw UploadProblem.auth("account_changed")
        notices.hideInactiveAccounts()
        library?.accountChanged()
        recover(appendAfterRunning = true)
    }

    fun signOut() {
        vault.clear()
        notices.hideInactiveAccounts()
        library?.accountChanged()
        recover()
    }

    fun listInbox(): Map<String, Any?> {
        val account = sessions?.current()
        val inbox = store.listShares(account?.owner)
        if (activeOwner() != account?.owner) throw UploadProblem.auth("account_changed")
        return mapOf(
            "mode" to (config?.mode ?: "disabled"),
            "staging_api_host" to config?.takeIf { it.mode == "staging" }?.apiBase?.host,
            "account" to account?.let {
                mapOf("id" to it.owner.userId.toString(), "email" to it.email, "realm" to it.owner.realm)
            },
            "shares" to inbox,
            "notifications_enabled" to (account != null && notices.permissionEnabled()),
        )
    }

    fun readLibrary(owner: UploadOwner, limit: Int, acknowledged: Set<UUID>): String =
        (library ?: throw UploadProblem.auth()).snapshot(owner, limit, acknowledged)

    fun requestLibrarySync(owner: UploadOwner) {
        if (activeOwner() != owner) throw UploadProblem.auth()
        library?.request(owner, urgent = true)
    }

    fun assign(localId: UUID, expectedUserId: UUID) {
        val owner = activeOwner()?.takeIf { it.userId == expectedUserId }
            ?: throw UploadProblem.auth("account_changed")
        store.updateProgress(localId) { previous ->
            if (previous.owner != null) throw UploadProblem.permanent("share_already_assigned")
            schedule(localId, waitForEnqueue = true)
            UploadProgress(owner)
        }
        changed()
    }

    fun scheduleReceipt(localId: UUID) = schedule(localId, waitForEnqueue = true)

    fun receiptSaved() = changed()

    fun recover(appendAfterRunning: Boolean = false) {
        if (config == null) return
        val owner = activeOwner()
        for (share in store.entries()) {
            val progress = share.progress
            if (progress.owner == null || progress.state.terminal) continue
            if (progress.owner != owner) {
                if (progress.state != UploadState.AUTH_REQUIRED) {
                    store.updateProgress(share.localId) {
                        if (it.state.terminal) it else it.copy(
                            state = UploadState.AUTH_REQUIRED, lastError = "authentication_required",
                        )
                    }
                }
                continue
            }
            if (progress.state == UploadState.AUTH_REQUIRED) {
                // An explicit sign-in must also wake work that is about to finish while paused.
                store.updateProgress(share.localId) {
                    schedule(share.localId, appendAfterRunning = true, waitForEnqueue = true)
                    if (it.state == UploadState.AUTH_REQUIRED) it.copy(state = UploadState.PENDING, lastError = null)
                    else it
                }
            } else {
                schedule(share.localId, appendAfterRunning = appendAfterRunning)
            }
        }
        notices.refreshRegistered(append = appendAfterRunning)
        library?.requestCurrent()
        changed()
    }

    fun addListener(listener: () -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: () -> Unit) {
        listeners.remove(listener)
    }

    private fun changed() {
        if (config != null) notices.hideInactiveAccounts()
        listeners.forEach { it() }
    }

    private fun schedule(localId: UUID, appendAfterRunning: Boolean = false, waitForEnqueue: Boolean = false) {
        val request = OneTimeWorkRequestBuilder<ShareUploadWorker>()
            .setInputData(workDataOf("local_id" to localId.toString()))
            .setConstraints(Constraints(requiredNetworkType = NetworkType.CONNECTED))
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, SECONDS)
            .build()
        val policy = if (appendAfterRunning) ExistingWorkPolicy.APPEND_OR_REPLACE else ExistingWorkPolicy.KEEP
        try {
            val operation = workManager.enqueueUniqueWork("itda-share-$localId", policy, request)
            // Work is persisted before publication when possible. The worker waits for the store lock.
            if (waitForEnqueue) operation.result.get(2, SECONDS)
        } catch (_: Exception) {
            // Receipt remains durable. Launcher recovery can enqueue again after a local scheduler failure.
        }
    }

    companion object {
        @Volatile private var instance: AndroidOutbox? = null

        fun get(context: Context): AndroidOutbox = instance ?: synchronized(this) {
            instance ?: AndroidOutbox(context.applicationContext).also { instance = it }
        }
    }
}
