package com.itda.itda_mobile

import android.content.Context
import android.os.Build
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.ListenableWorker.Result
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit.SECONDS
import org.json.JSONObject

internal class AndroidNotifications(
    context: Context,
    private val config: UploadConfig?,
    private val sessions: SupabaseSessions?,
    private val shares: LocalShareStore,
    private val onChange: () -> Unit,
    private val surface: NoticeSurface = AndroidNoticeSurface(context, mock = config?.mode == "mock"),
    store: NoticeStore = NoticeStore(File(context.noBackupFilesDir, "notification-inbox-v1")),
) {
    private val lifecycle = NoticeLifecycle(store, surface, ::activeOwner, onChange)
    private val workManager by lazy { WorkManager.getInstance(context) }
    private val running = ConcurrentHashMap.newKeySet<NoticeRef>()

    private fun activeOwner() = sessions?.current()?.owner

    fun permissionEnabled(): Boolean = config != null && surface.canPost()

    fun ownsAcknowledgment(ref: NoticeRef): Boolean =
        activeOwner() == ref.owner && shares.acknowledged(ref) != null

    fun registered(ref: NoticeRef) {
        // Registration can return an idempotency replay. Read current content before posting.
        if (activeOwner() == ref.owner) schedule(ref, wait = true)
    }

    fun refreshRegistered(append: Boolean = false) {
        hideInactiveAccounts()
        val owner = activeOwner() ?: return
        for (ref in acknowledgedRefs(owner)) schedule(ref, append)
    }

    fun relocalize() {
        val owner = activeOwner() ?: return
        for (ref in acknowledgedRefs(owner)) lifecycle.refreshPresentation(ref)
    }

    private fun acknowledgedRefs(owner: UploadOwner): List<NoticeRef> = shares.entries().mapNotNull { share ->
        share.progress.serverContentId?.takeIf { share.progress.owner == owner }?.let { NoticeRef(owner, it) }
    }.distinct()

    fun refreshSynced(owner: UploadOwner, ids: Set<UUID>) {
        if (activeOwner() != owner) return
        for (id in ids) schedule(NoticeRef(owner, id), append = true)
    }

    fun hideInactiveAccounts() = lifecycle.hideInactiveAccounts()

    fun dismiss(link: NoticeLink) {
        if (lifecycle.dismiss(link.ref, link.generation)) schedule(link.ref, append = true, wait = true)
    }

    fun restore(ref: NoticeRef) {
        if (!ownsAcknowledgment(ref)) throw UploadProblem.auth()
        if (!lifecycle.requestRestore(ref)) throw UploadProblem.permanent("notification_unavailable")
        schedule(ref, append = true, wait = true)
    }

    fun status(ref: NoticeRef): Map<String, Any?> {
        requireOwner(ref)
        return lifecycle.read(ref)?.summary() ?: emptyMap()
    }

    fun details(ref: NoticeRef): Map<String, Any?> {
        requireOwner(ref)
        return contentResult(ref, fetch(ref, api(UploadHttp())))
    }

    fun edit(ref: NoticeRef, patch: JSONObject): Map<String, Any?> {
        requireOwner(ref)
        val reply = api(UploadHttp()).request(ref.owner, "PATCH", contentPath(ref), patch)
        if (reply.status == 409) throw UploadProblem.permanent("version_conflict")
        return contentResult(ref, reply.expectJson(200))
    }

    private fun contentResult(ref: NoticeRef, response: JSONObject): Map<String, Any?> {
        requireOwner(ref)
        val share = shares.acknowledged(ref)
        val content = NoticeContent.fromWire(response, ref, share?.receipt)
        if (share != null) lifecycle.observe(ref, content)
        requireOwner(ref)
        return mapOf(
            "content" to response.toString(),
            "mode" to config?.mode,
            "notice" to (lifecycle.read(ref)?.summary() ?: mapOf("dismissed" to content.state.dismissed)),
        )
    }

    fun run(ref: NoticeRef, http: UploadHttp): Result {
        if (!running.add(ref)) return Result.retry()
        try {
            if (activeOwner() != ref.owner) return Result.success()
            val share = shares.acknowledged(ref) ?: return Result.success()
            val api = api(http)
            val event = lifecycle.read(ref)?.event?.takeUnless { it.blocked }
            if (event != null) {
                try {
                    return if (process(ref, event, api, share.receipt)) Result.retry() else Result.success()
                } catch (problem: UploadProblem) {
                    if (problem.state != UploadState.PERMANENT_FAILURE) throw problem
                    lifecycle.reject(ref, event, problem.code)
                }
            }
            val response = fetch(ref, api)
            lifecycle.observe(ref, NoticeContent.fromWire(response, ref, share.receipt))
            return Result.success()
        } catch (problem: UploadProblem) {
            if (problem.state == UploadState.AUTH_REQUIRED) onChange()
            if (problem.code == "http_404" && activeOwner() == ref.owner) surface.cancel(ref)
            return if (problem.state == UploadState.RETRY_WAITING) Result.retry() else Result.success()
        } catch (_: Exception) {
            return Result.retry()
        } finally {
            running.remove(ref)
        }
    }

    private fun process(ref: NoticeRef, event: NoticeEvent, api: AuthenticatedApi, receipt: JSONObject): Boolean {
        val restore = event.operation == NoticeOperation.RESTORE
        val body = JSONObject().put("expected_revision", event.revision)
        val path = if (restore) {
            body.put("expected_generation", event.generation)
            "${contentPath(ref)}/notification/restore"
        } else {
            body.put("content_id", ref.contentId.toString()).put("event_type", "dismissed")
                .put("generation", event.generation)
            "v1/notification-events"
        }
        val reply = api.request(ref.owner, "POST", path, body, event.key)
        if (reply.status == 409 && reply.errorCode() == "notification_conflict") {
            val current = NoticeContent.fromWire(fetch(ref, api), ref, receipt)
            return lifecycle.resolveConflict(ref, event, current)
        }
        val result = reply.expectJson(200)
        val state = decodeServer {
            val state = NoticeState.fromWire(result.getJSONObject("state"), ref)
            val applied = result.getBoolean("applied")
            val reason = result.getString("reason")
            val valid = if (restore) {
                !state.dismissed && if (applied) {
                    reason == "applied" && state.generation == event.generation + 1 && state.revision > event.revision
                } else {
                    reason == "already_active" && state.generation == event.generation && state.revision >= event.revision
                }
            } else {
                (state.generation > event.generation && !applied && reason == "stale_generation") ||
                    (state.generation == event.generation && state.dismissed &&
                        if (applied) reason == "applied" && state.revision > event.revision
                        else reason == "already_dismissed" && state.revision >= event.revision)
            }
            require(valid)
            state
        }
        // A retry may replay the original response after a subsequent dismissal.
        // Reconcile current state before applying any visible change from the acknowledgment.
        val current = NoticeContent.fromWire(fetch(ref, api), ref, receipt)
        if (state.merge(current.state) != current.state) throw UploadProblem.retry("notification_snapshot_behind")
        lifecycle.acknowledge(ref, event, current)
        return false
    }

    private fun requireOwner(ref: NoticeRef) {
        if (activeOwner() != ref.owner) throw UploadProblem.auth()
    }

    private fun api(http: UploadHttp) = AuthenticatedApi(
        config ?: throw UploadProblem.auth(), sessions ?: throw UploadProblem.auth(), http,
    )

    private fun fetch(ref: NoticeRef, api: AuthenticatedApi): JSONObject =
        api.request(ref.owner, "GET", contentPath(ref)).expectJson(200)

    private fun contentPath(ref: NoticeRef) = "v1/contents/${ref.contentId}"

    private fun schedule(ref: NoticeRef, append: Boolean = false, wait: Boolean = false) {
        try {
            val request = OneTimeWorkRequestBuilder<NoticeWorker>()
                .setInputData(workDataOf(
                    "realm" to ref.owner.realm, "owner_id" to ref.owner.userId.toString(),
                    "content_id" to ref.contentId.toString(),
                ))
                .setConstraints(Constraints(requiredNetworkType = NetworkType.CONNECTED))
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, SECONDS)
                .build()
            val policy = if (append) ExistingWorkPolicy.APPEND_OR_REPLACE else ExistingWorkPolicy.KEEP
            val operation = workManager.enqueueUniqueWork(ref.tag, policy, request)
            if (wait) operation.result.get(2, SECONDS)
        } catch (_: Exception) {
            // Pending mutations remain on disk for the next launcher or account recovery.
        }
    }
}

class NoticeWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    private val http by lazy { UploadHttp(if (Build.VERSION.SDK_INT >= 28) network else null) }

    override fun doWork(): Result {
        val ref = try {
            val owner = UploadOwner(
                parseUuid(requireNotNull(inputData.getString("owner_id"))),
                requireNotNull(inputData.getString("realm")),
            )
            NoticeRef(owner, parseUuid(requireNotNull(inputData.getString("content_id"))))
        } catch (_: IllegalArgumentException) {
            return Result.failure()
        }
        return AndroidOutbox.get(applicationContext).notices.run(ref, http)
    }

    override fun onStopped() {
        http.stop()
        super.onStopped()
    }
}
