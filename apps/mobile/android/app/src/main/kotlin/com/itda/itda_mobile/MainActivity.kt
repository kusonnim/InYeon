package com.itda.itda_mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var localSharesChannel: MethodChannel? = null
    private var updates: EventChannel? = null
    private var sink: EventChannel.EventSink? = null
    private val onChange: () -> Unit = { runOnUiThread { sink?.success(null) } }

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
                shareIo.execute {
                    try {
                        when (call.method) {
                            "listLocalInbox" -> result.success(outbox.listInbox())
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
                            else -> result.notImplemented()
                        }
                    } catch (error: Exception) {
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

    private companion object {
        val authIo = Executors.newSingleThreadExecutor()
    }
}
