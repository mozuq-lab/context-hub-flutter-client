package com.mozuqlab.context_hub_client

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * 確認待ちの通知（任意の設定）。数時間おきの確認の登録と、通知の表示・消去を行う。
 * 何を新しい確認待ちとするかはFlutter側が決め、ここは渡された短い文を出すだけにする。
 */
object AttentionCheck {
    const val PERMISSION = "android.permission.POST_NOTIFICATIONS"
    const val PERMISSION_REQUEST = 8832
    private const val JOB_ID = 8840
    private const val NOTIFICATION_ID = 8841
    private const val CHANNEL = "attention"
    private const val PREFS = "attention"
    private const val KEY = "last"
    /** 確認の間隔。端末の都合で遅れることがある。 */
    private const val PERIOD_MS = 4 * 60 * 60 * 1000L

    /** 端末でこのアプリの通知が許可されているか。 */
    fun allowed(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(PERMISSION) != PackageManager.PERMISSION_GRANTED) return false
        val manager = context.getSystemService(NotificationManager::class.java) ?: return false
        return manager.areNotificationsEnabled()
    }

    /** 数時間おきの確認を登録する。登録済みなら間隔を数え直さない。端末を再起動すると消える。 */
    fun schedule(context: Context) {
        val scheduler = context.getSystemService(JobScheduler::class.java) ?: return
        if (scheduler.getPendingJob(JOB_ID) != null) return
        val job = JobInfo.Builder(JOB_ID, ComponentName(context, AttentionJobService::class.java))
            .setPeriodic(PERIOD_MS)
        if (Build.VERSION.SDK_INT >= 26) job.setRequiresBatteryNotLow(true)
        scheduler.schedule(job.build())
    }

    /** 確認の登録と、出ている通知を消す。 */
    fun cancel(context: Context) {
        context.getSystemService(JobScheduler::class.java)?.cancel(JOB_ID)
        clear(context)
    }

    /** 確認待ちが増えたことを通知する。keyが前回と同じなら出し直さない。 */
    fun show(context: Context, key: String, title: String, text: String) {
        require(key.length in 1..64 && title.length in 1..80 && text.length <= 200)
        if (!allowed(context)) return
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.getString(KEY, null) == key) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= 26) {
            // 音を鳴らさない重要度にする。急ぎの知らせではない。
            val channel = NotificationChannel(CHANNEL, context.getString(R.string.attention_channel), NotificationManager.IMPORTANCE_LOW)
            channel.description = context.getString(R.string.attention_channel_description)
            manager.createNotificationChannel(channel)
        }
        val open = PendingIntent.getActivity(
            context, 3,
            Intent(context, MainActivity::class.java).setAction(LaunchActions.ATTENTION)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL) else Notification.Builder(context)
        builder.setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(open)
            .setAutoCancel(true)
        manager.notify(NOTIFICATION_ID, builder.build())
        prefs.edit().putString(KEY, key).apply()
    }

    /** 出ている通知を消し、次に増えたときにまた通知できるようにする。 */
    fun clear(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(KEY).apply()
        context.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
    }
}

/**
 * 数時間おきに呼ばれ、画面のないFlutterエンジンで確認待ちの確認（Dartのattention_check）を動かす。
 * 端末内の同期済みVaultと設定を読むだけで、Vaultには書かず、ネットワークにも接続しない。
 */
class AttentionJobService : JobService() {
    private companion object {
        /** これを過ぎても終わらない確認は打ち切る。 */
        const val TIMEOUT_MS = 5 * 60 * 1000L
    }
    private val main = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null
    private var bridge: VaultBridge? = null
    private var timeout: Runnable? = null

    override fun onStartJob(params: JobParameters): Boolean {
        // アプリの画面が出ている間は、アプリが件数を出すので確認しない。通知が許可されていなければ読まない。
        if (MainActivity.visible || engine != null || !AttentionCheck.allowed(this)) return false
        return try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)
            val created = FlutterEngine(applicationContext)
            engine = created
            val done = Runnable { finish(params) }
            // Dart側が終わりを伝えたら、応答を返し終えてから片付ける。
            bridge = VaultBridge(applicationContext, created.dartExecutor.binaryMessenger,
                backgroundDone = { main.post(done) })
            timeout = done
            main.postDelayed(done, TIMEOUT_MS)
            created.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "attentionCheck"))
            true
        } catch (_: Exception) {
            release()
            false
        }
    }

    private fun finish(params: JobParameters) {
        if (engine == null) return
        release()
        jobFinished(params, false)
    }

    private fun release() {
        timeout?.let { main.removeCallbacks(it) }
        timeout = null
        bridge?.close()
        bridge = null
        engine?.destroy()
        engine = null
    }

    override fun onStopJob(params: JobParameters): Boolean {
        release()
        return false
    }
}
