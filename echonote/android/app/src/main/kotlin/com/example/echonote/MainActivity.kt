package com.example.echonote

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var mic: MicStreamChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        mic = MicStreamChannel(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
            .also { it.activity = this }
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
