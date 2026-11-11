package com.itda.itda_mobile

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private var localSharesChannel: MethodChannel? = null
    private var updates: EventChannel? = null
    private var sink: EventChannel.EventSink? = null
    private val onChange: () -> Unit = { runOnUiThread { sink?.success(null) } }
    private val pendingNotice = AtomicReference<NoticeLink?>()

    override fun onCreate(savedInstanceState: Bundle?) {
        if (savedInstanceState?.getBoolean("notice_consumed") != true) {
            pendingNotice.set(NoticeIntents.parse(intent))
        }
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pendingNotice.set(NoticeIntents.parse(intent))
        onChange()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean("notice_consumed", pendingNotice.get() == null)
    }

    override fun onResume() {
        super.onResume()
        if (localSharesChannel != null) refreshNotices()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val outbox = AndroidOutbox.get(applicationContext)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        updates = EventChannel(messenger, "com.itda.itda_mobile/share_updates").apply {
            setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    sink = events
                    outbox.addListener(onChange)
                }

                override fun onCancel(arguments: Any?) {
                    sink = null
                    outbox.removeListener(onChange)
                }
            })
        }
        localSharesChannel = MethodChannel(
            messenger,
            "com.itda.itda_mobile/local_shares",
        ).apply {
            setMethodCallHandler { call, result ->
                if (call.method == "openExternalLink") {
                    result.success(launchExternalLink(call.arguments as? String, ::startActivity))
                    return@setMethodCallHandler
                }
                val executor = when (call.method) {
                    "noticeDetails", "editNoticeContent" -> contentIo
                    "readLibrary" -> cacheIo
                    else -> shareIo
                }
                executor.execute {
                    try {
                        when (call.method) {
                            "getAppLanguage" -> result.success(AppLanguage.get(applicationContext))
                            "setAppLanguage" -> {
                                AppLanguage.set(applicationContext, requireNotNull(call.argument("language")))
                                runCatching { outbox.notices.relocalize() }
                                result.success(null)
                            }
                            "listLocalInbox" -> result.success(outbox.listInbox())
                            "readLibrary" -> {
                                val limit = requireNotNull(call.argument<Number>("limit")).toInt()
                                val ids = call.argument<List<String>>("acknowledged")?.mapTo(mutableSetOf(), ::parseUuid)
                                result.success(outbox.readLibrary(call.uploadOwner(), limit, ids.orEmpty()))
                            }
                            "syncLibrary" -> {
                                outbox.requestLibrarySync(call.uploadOwner())
                                result.success(null)
                            }
                            "readLocalSource" -> result.success(outbox.originals.read(
                                parseUuid(requireNotNull(call.argument("local_id"))),
                            ))
                            "readNoticeOriginal" -> result.success(outbox.originals.readRegistered(call.noticeRef()))
                            "openSavedDocument" -> {
                                val localId = call.argument<String>("local_id")
                                val pdf = if (localId != null) outbox.originals.pdf(parseUuid(localId))
                                    else outbox.originals.registeredPdf(call.noticeRef())
                                runOnUiThread {
                                    try {
                                        startActivity(SavedPdfProvider.viewIntent(this@MainActivity, pdf.localId))
                                        result.success(null)
                                    } catch (_: ActivityNotFoundException) {
                                        result.error("document_viewer_unavailable", null, null)
                                    } catch (_: SecurityException) {
                                        result.error("document_unavailable", null, null)
                                    }
                                }
                            }
                            "signIn" -> signIn(outbox, call, result)
                            "signOut" -> {
                                outbox.signOut()
                                result.success(null)
                            }
                            "assignShare" -> {
                                val id = parseUuid(requireNotNull(call.argument<String>("local_id")))
                                val account = parseUuid(requireNotNull(call.argument<String>("account_id")))
                                outbox.assign(id, account)
                                result.success(null)
                            }
                            "takeNoticeNavigation" -> {
                                val link = pendingNotice.getAndSet(null)?.takeIf {
                                    it.destination != NoticeDestination.DISMISS && outbox.notices.ownsAcknowledgment(it.ref)
                                }
                                result.success(link?.let { it.ref.toMap() + ("destination" to it.destination.wire) })
                            }
                            "noticeDetails" -> result.success(outbox.notices.details(call.noticeRef()))
                            "noticeStatus" -> result.success(outbox.notices.status(call.noticeRef()))
                            "editNoticeContent" -> {
                                val version = requireNotNull(call.argument<Number>("expected_version")).toLong()
                                val patch = JSONObject().put("expected_version", version)
                                for (field in listOf("title", "user_note")) {
                                    if (call.hasArgument(field)) patch.put(field, call.argument<String>(field) ?: JSONObject.NULL)
                                }
                                if (call.hasArgument("workflow_status")) {
                                    val workflow = call.argument<String>("workflow_status")
                                    require(workflow == "pending" || workflow == "completed" || workflow == "archived")
                                    patch.put("workflow_status", workflow)
                                }
                                val ref = call.noticeRef()
                                val updated = outbox.notices.edit(ref, patch)
                                outbox.library?.request(ref.owner)
                                result.success(updated)
                            }
                            "restoreNotice" -> {
                                outbox.notices.restore(call.noticeRef())
                                result.success(null)
                            }
                            "refreshNotices" -> {
                                outbox.notices.refreshRegistered(append = true)
                                result.success(null)
                            }
                            "enableNotices" -> {
                                if (outbox.activeOwner() == null) throw UploadProblem.auth()
                                runOnUiThread { enableNotices(outbox.notices) }
                                result.success(null)
                            }
                            else -> result.notImplemented()
                        }
                    } catch (error: Exception) {
                        if (error is UploadProblem && error.state == UploadState.AUTH_REQUIRED) {
                            outbox.notices.hideInactiveAccounts()
                            onChange()
                        }
                        report(result, error)
                    }
                }
            }
        }
        shareIo.execute {
            try {
                outbox.recover()
            } catch (_: Exception) {
                // Listing can report a local storage error without blocking the fixture library.
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        localSharesChannel?.setMethodCallHandler(null)
        localSharesChannel = null
        updates?.setStreamHandler(null)
        updates = null
        sink = null
        AndroidOutbox.get(applicationContext).removeListener(onChange)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun signIn(outbox: AndroidOutbox, call: MethodCall, result: MethodChannel.Result) {
        val email = call.argument<String>("email")?.trim().orEmpty()
        val password = call.argument<String>("password").orEmpty()
        if (email.isEmpty() || email.length > 320 || password.isEmpty() || password.length > 4096) {
            result.error("invalid_sign_in", "Enter your email and password.", null)
            return
        }
        val snapshot = outbox.snapshotForSignIn()
        authIo.execute {
            try {
                val session = outbox.requestSession(email, password)
                shareIo.execute {
                    try {
                        outbox.installSession(snapshot, session)
                        result.success(null)
                    } catch (error: Exception) {
                        report(result, error)
                    }
                }
            } catch (error: Exception) {
                report(result, error)
            }
        }
    }

    private fun report(result: MethodChannel.Result, error: Exception) {
        result.error((error as? UploadProblem)?.code ?: "local_inbox_unavailable", null, null)
    }

    private fun MethodCall.uploadOwner() =
        UploadOwner(parseUuid(requireNotNull(argument("owner_id"))), requireNotNull(argument("realm")))

    private fun MethodCall.noticeRef() = NoticeRef(uploadOwner(), parseUuid(requireNotNull(argument("content_id"))))

    private fun enableNotices(notices: AndroidNotifications) {
        if (notices.permissionEnabled()) return
        if (Build.VERSION.SDK_INT >= 33 && requestNoticePermission()) return
        val settings = if (Build.VERSION.SDK_INT >= 26) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null))
        }
        startActivity(settings)
    }

    @androidx.annotation.RequiresApi(33)
    private fun requestNoticePermission(): Boolean {
        val permission = Manifest.permission.POST_NOTIFICATIONS
        if (ContextCompat.checkSelfPermission(this, permission) != PackageManager.PERMISSION_GRANTED) {
            val preferences = getPreferences(MODE_PRIVATE)
            if (!preferences.getBoolean("notice_permission_requested", false) ||
                ActivityCompat.shouldShowRequestPermissionRationale(this, permission)
            ) {
                preferences.edit { putBoolean("notice_permission_requested", true) }
                ActivityCompat.requestPermissions(this, arrayOf(permission), NOTICE_PERMISSION_REQUEST)
                return true
            }
        }
        return false
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == NOTICE_PERMISSION_REQUEST) refreshNotices()
    }

    private fun refreshNotices() {
        val context = applicationContext
        shareIo.execute {
            try {
                val outbox = AndroidOutbox.get(context)
                outbox.notices.refreshRegistered()
                outbox.library?.requestCurrent()
            } catch (_: Exception) {
                // Saved receipts can be recovered on a later refresh.
            }
            onChange()
        }
    }

    private companion object {
        const val NOTICE_PERMISSION_REQUEST = 301
        val authIo = Executors.newSingleThreadExecutor()
        val contentIo = Executors.newFixedThreadPool(2)
        val cacheIo = Executors.newSingleThreadExecutor()
    }
}
