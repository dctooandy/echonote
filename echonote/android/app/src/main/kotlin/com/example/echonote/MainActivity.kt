package com.example.echonote

import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var mic: MicStreamChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        mic = MicStreamChannel(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
            .also { it.activity = this }
        // Keeps the screen from turning off while recording or transcribing
        // (spec feature-keep-screen-awake).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "echonote/screen")
            .setMethodCallHandler { call, result ->
                val on = call.arguments as? Boolean
                if (call.method != "setKeepAwake" || on == null) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (on) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                result.success(null)
            }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (mic?.onRequestPermissionsResult(requestCode, grantResults) != true) {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        }
    }

    override fun onStop() {
        super.onStop()
        mic?.onAppBackgrounded()
    }

    override fun onDestroy() {
        mic?.activity = null
        super.onDestroy()
    }
}
