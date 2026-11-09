package com.itda.itda_mobile

import android.content.Context
import android.os.Build
import androidx.work.ListenableWorker.Result
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import org.json.JSONException

class ShareUploadWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    private val http by lazy { UploadHttp(if (Build.VERSION.SDK_INT >= 28) network else null) }

    override fun doWork(): Result {
        val id = try {
            parseUuid(inputData.getString("local_id") ?: return Result.failure())
        } catch (_: IllegalArgumentException) {
            return Result.failure()
        }
        return AndroidOutbox.get(applicationContext).processor.run(id, http)
    }

    override fun onStopped() {
        http.stop()
        super.onStopped()
    }
}

internal class UploadProcessor(
    private val store: LocalShareStore,
    private val config: UploadConfig?,
    private val sessions: SupabaseSessions?,
    private val onChange: () -> Unit = {},
) {
    // A cancelled worker can still be unwinding an HTTP call while WorkManager restarts it.
    private val running = ConcurrentHashMap.newKeySet<UUID>()

    fun run(id: UUID, http: UploadHttp = UploadHttp()): Result {
        if (!running.add(id)) return Result.retry()
        try {
            val share = store.read(id) ?: return Result.success()
            if (share.progress.state.terminal) return Result.success()
            val owner = share.progress.owner ?: throw UploadProblem.auth()
            val activeSessions = sessions ?: throw UploadProblem.auth()
            activeSessions.requireOwner(owner)
            store.updateProgress(id) { it.copy(state = UploadState.UPLOADING, lastError = null) }
            onChange()

            val contentId = UploadPipeline(checkNotNull(config), activeSessions, http).submit(share) { asset ->
                store.updateProgress(id) { it.copy(asset = asset) }
            }
            store.updateProgress(id) {
                it.copy(state = UploadState.SYNCHRONIZED, serverContentId = contentId, lastError = null)
            }
            onChange()
            return Result.success()
        } catch (problem: UploadProblem) {
            return recordProblem(id, problem)
        } catch (_: JSONException) {
            return recordProblem(id, UploadProblem.permanent("invalid_local_receipt"))
        } catch (_: IllegalArgumentException) {
            return recordProblem(id, UploadProblem.permanent("invalid_local_receipt"))
        } catch (_: Exception) {
            return recordProblem(id, UploadProblem.retry("local_storage_unavailable"))
        } finally {
            running.remove(id)
        }
    }

    private fun recordProblem(id: UUID, problem: UploadProblem): Result {
        try {
            val activeOwner = sessions?.current()?.owner
            val updated = store.updateProgress(id) { current ->
                if (current.state.terminal) return@updateProgress current
                if (current.owner != activeOwner) {
                    current.copy(state = UploadState.AUTH_REQUIRED, lastError = "authentication_required")
                } else {
                    current.copy(state = problem.state, lastError = problem.code)
                }
            }
            onChange()
            return if (updated.state == UploadState.RETRY_WAITING) Result.retry() else Result.success()
        } catch (_: Exception) {
            return Result.retry()
        }
    }
}
