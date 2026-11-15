package com.mozuqlab.context_hub_client

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import android.content.Intent
import android.os.Bundle

class MainActivity : FlutterActivity() {
    companion object {
        /** アプリの画面が出ているか。出ている間は、アプリを閉じている間の確認を行わない。 */
        @Volatile
        var visible = false
            private set
    }
    private lateinit var bridge: VaultBridge
    /** ショートカットやウィジェットで選ばれ、まだFlutter側が受け取っていない操作。 */
    private var launchAction: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // 画面の作り直し（回転など）では、前回の操作を繰り返さない。
        if (savedInstanceState == null) launchAction = LaunchActions.of(intent)
        super.onCreate(savedInstanceState)
        LaunchActions.publishShortcuts(this)
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = VaultBridge(this, flutterEngine.dartExecutor.binaryMessenger, this) {
            val action = launchAction
            launchAction = null
            action
        }
    }
    override fun onStart() {
        super.onStart()
        visible = true
    }
    override fun onStop() {
        visible = false
        super.onStop()
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (::bridge.isInitialized) bridge.permissionResult(requestCode)
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val action = LaunchActions.of(intent) ?: return
        launchAction = action
        if (::bridge.isInitialized) bridge.notifyLaunchAction()
    }
    @Deprecated("Activity結果はFlutter側の限定bridgeへ渡す")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (!bridge.activityResult(requestCode, resultCode, data)) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }
}
