package com.itda.itda_mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var localSharesChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val context = applicationContext
        localSharesChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.itda.itda_mobile/local_shares",
        ).apply {
            setMethodCallHandler { call, result ->
                if (call.method != "listPendingShares") {
                    result.notImplemented()
                } else {
                    shareIo.execute {
                        try {
                            result.success(localShareStore(context).listPending())
                        } catch (_: Exception) {
                            result.error("local_inbox_unavailable", "Could not read the local inbox.", null)
                        }
                    }
                }
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        localSharesChannel?.setMethodCallHandler(null)
        localSharesChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
