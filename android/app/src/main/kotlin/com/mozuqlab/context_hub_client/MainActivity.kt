package com.mozuqlab.context_hub_client

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import android.content.Intent

class MainActivity : FlutterActivity() {
    private lateinit var bridge: VaultBridge
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = VaultBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }
    @Deprecated("Activity結果はFlutter側の限定bridgeへ渡す")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (!bridge.activityResult(requestCode, resultCode, data)) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }
}
