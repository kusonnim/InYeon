package com.itda.itda_mobile

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.ListenableWorker.Result
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit.SECONDS
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONArray
import org.json.JSONObject

internal class AndroidLibrarySync(
    context: Context,
    private val config: UploadConfig,
    private val sessions: SupabaseSessions,
    private val shares: LocalShareStore,
    private val onChange: () -> Unit,
    private val onContentChanges: (UploadOwner, Set<UUID>) -> Unit,
) {
    private val cache = LibraryCache(File(context.noBackupFilesDir, "library-cache-v1"))
    private val manager by lazy { WorkManager.getInstance(context) }
    private val scheduler = Executors.newSingleThreadExecutor()
    private val connectivity = checkNotNull(context.getSystemService(ConnectivityManager::class.java))
    private val available = AtomicReference(connectivity.activeNetwork)
    private val phases = ConcurrentHashMap<UploadOwner, Phase>()
    private val running = ConcurrentHashMap.newKeySet<UploadOwner>()

    private enum class Phase { CACHED, SYNCING, CURRENT, RETRYING, FAILED, OFFLINE }

    init {
        connectivity.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                val previous = available.getAndSet(network)
                if (previous != network) requestCurrent(urgent = true)
            }

            override fun onLost(network: Network) {
                if (available.compareAndSet(network, null)) scheduler.execute(onChange)
            }
        })
    }

    fun accountChanged() {
        val owner = sessions.current()?.owner
        phases.keys.removeAll { it != owner }
    }

    fun requestCurrent(urgent: Boolean = false) {
        sessions.current()?.owner?.let { request(it, urgent) }
    }

    fun request(owner: UploadOwner, urgent: Boolean = false, wait: Boolean = false) {
        val scheduled = scheduler.submit { enqueue(owner, urgent) }
        if (wait) {
            try {
                scheduled.get(5, SECONDS)
            } catch (_: Exception) {
                // Launch, resume, or reconnect can enqueue again from the durable checkpoint.
            }
        }
    }

    fun snapshot(owner: UploadOwner, limit: Int, acknowledged: Set<UUID>): String {
        sessions.requireOwner(owner)
        val view = cache.snapshot(owner, limit, acknowledged)
        sessions.requireOwner(owner)
        val phase = if (available.get() == null) Phase.OFFLINE else phases[owner] ?: Phase.CACHED
        return JSONObject()
            .put("items", view.items).put("has_more", view.hasMore).put("initialized", view.initialized)
            .put("removed", JSONArray(view.removed.map(UUID::toString)))
            .put("phase", phase.name.lowercase())
            .toString()
    }

    fun run(owner: UploadOwner, http: UploadHttp): Result {
        if (sessions.current()?.owner != owner) return Result.success()
        if (!running.add(owner)) return Result.retry()
        val changed = mutableSetOf<UUID>()
        try {
            setPhase(owner, Phase.SYNCING)
            val engine = LibrarySyncEngine(
                owner, cache, LibrarySyncApi(AuthenticatedApi(config, sessions, http)),
                verifyOwner = { sessions.requireOwner(owner) },
                acknowledged = { acknowledgedBy(owner) },
                onApplied = { changed.addAll(it) },
            )
            engine.synchronize()
            setPhase(owner, Phase.CURRENT)
            return Result.success()
        } catch (problem: UploadProblem) {
            return when (problem.state) {
                UploadState.AUTH_REQUIRED -> {
                    phases.remove(owner)
                    onChange()
                    Result.success()
                }
                UploadState.RETRY_WAITING -> {
                    setPhase(owner, Phase.RETRYING)
                    Result.retry()
                }
                else -> {
                    setPhase(owner, Phase.FAILED)
                    Result.success()
                }
            }
        } catch (_: Exception) {
            setPhase(owner, Phase.RETRYING)
            return Result.retry()
        } finally {
            if (changed.isNotEmpty() && sessions.current()?.owner == owner) {
                try {
                    onContentChanges(owner, changed.intersect(acknowledgedBy(owner)))
                } catch (_: Exception) {
                    // Notification recovery is independent of the committed sync pages.
                }
            }
            running.remove(owner)
        }
    }

    private fun acknowledgedBy(owner: UploadOwner): Set<UUID> =
        shares.entries().mapNotNullTo(mutableSetOf()) { share ->
            share.progress.serverContentId?.takeIf { share.progress.owner == owner }
        }

    private fun enqueue(owner: UploadOwner, urgent: Boolean) {
        if (sessions.current()?.owner != owner) return
        try {
            val name = "itda-library-${NoticeRef.ownerPrefix(owner)}"
            val work = manager.getWorkInfosForUniqueWork(name).get(2, SECONDS)
            val executing = work.any { it.state == WorkInfo.State.RUNNING }
            val queued = work.any { it.state == WorkInfo.State.ENQUEUED || it.state == WorkInfo.State.BLOCKED }
            // A queued job covers the trigger. A running job may have already read its last page.
            val expedite = urgent && !executing && phases[owner] == Phase.RETRYING
            if (queued && !expedite) {
                if (phases[owner] == null) setPhase(owner, Phase.SYNCING)
                else onChange()
                return
            }
            val policy = if (expedite) ExistingWorkPolicy.REPLACE else ExistingWorkPolicy.APPEND_OR_REPLACE
            val request = OneTimeWorkRequestBuilder<LibrarySyncWorker>()
                .setInputData(workDataOf("owner_id" to owner.userId.toString(), "realm" to owner.realm))
                .setConstraints(Constraints(requiredNetworkType = NetworkType.CONNECTED))
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, SECONDS)
                .build()
            if (!executing) setPhase(owner, Phase.SYNCING)
            manager.enqueueUniqueWork(name, policy, request).result.get(2, SECONDS)
        } catch (_: Exception) {
            setPhase(owner, Phase.RETRYING)
        }
    }

    private fun setPhase(owner: UploadOwner, phase: Phase) {
        if (sessions.current()?.owner != owner) return
        phases[owner] = phase
        onChange()
    }
}

class LibrarySyncWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    private val http by lazy {
        UploadHttp(if (Build.VERSION.SDK_INT >= 28) network else null, maxResponseBytes = 8L * 1024 * 1024)
    }

    override fun doWork(): Result {
        val owner = try {
            UploadOwner(parseUuid(requireNotNull(inputData.getString("owner_id"))), requireNotNull(inputData.getString("realm")))
        } catch (_: IllegalArgumentException) {
            return Result.failure()
        }
        return AndroidOutbox.get(applicationContext).library?.run(owner, http) ?: Result.success()
    }

    override fun onStopped() {
        http.stop()
        super.onStopped()
    }
}
