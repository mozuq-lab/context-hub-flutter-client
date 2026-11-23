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
 * アプリを閉じている間の通知（任意の設定）。数時間おきの確認の登録と、通知の表示・消去を行う。
 * 通知は確認待ち（attention）と期日（due）の2種類で、数時間おきの確認は両方で共有する。
 * 何を知らせるかはFlutter側が決め、ここは渡された短い文を出すだけにする。
 */
object AttentionCheck {
    const val PERMISSION = "android.permission.POST_NOTIFICATIONS"
    const val PERMISSION_REQUEST = 8832
    private const val JOB_ID = 8840
    private const val PREFS = "attention"
    /** 確認の間隔。端末の都合で遅れることがある。 */
    private const val PERIOD_MS = 4 * 60 * 60 * 1000L

    /** 通知の種類ごとの、お知らせの種類（チャンネル）・通知のID・前回の鍵の保存名・押したときの操作。 */
    private class Kind(
        val channel: String, val id: Int, val key: String, val action: String, val request: Int,
        val name: Int, val description: Int, val importance: Int,
    )
    private val kinds = mapOf(
        // 音を鳴らさない重要度にする。急ぎの知らせではない。
        "attention" to Kind("attention", 8841, "last", LaunchActions.ATTENTION, 3,
            R.string.attention_channel, R.string.attention_channel_description, NotificationManager.IMPORTANCE_LOW),
        // 期日は気づいてもらうための知らせなので、端末の標準の重要度にする（夜はFlutter側で通知しない）。
        "due" to Kind("due", 8842, "due", LaunchActions.DUE, 4,
            R.string.due_channel, R.string.due_channel_description, NotificationManager.IMPORTANCE_DEFAULT),
    )
    private fun kindOf(name: Any?): Kind = requireNotNull(kinds[(name ?: "attention") as? String])

    /**
     * 端末でこのアプリの通知が許可されているか。[kind]を渡すと、そのお知らせの種類が止められていないかも確かめる。
     */
    fun allowed(context: Context, kind: Any? = null): Boolean {
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(PERMISSION) != PackageManager.PERMISSION_GRANTED) return false
        val manager = context.getSystemService(NotificationManager::class.java) ?: return false
        if (!manager.areNotificationsEnabled()) return false
        // 端末の設定で、このお知らせの種類だけを止めている場合。まだ一度も通知していなければ種類はない。
        if (kind != null && Build.VERSION.SDK_INT >= 26 &&
            manager.getNotificationChannel(kindOf(kind).channel)?.importance == NotificationManager.IMPORTANCE_NONE) return false
        return true
    }

    private const val ACTIVE = "active"

    /**
     * 有効にしている通知の種類を覚える（Flutter側の設定と同じもの）。確認を行うかの判断に使う。
     * 知らない種類は覚えない。
     */
    fun setActive(context: Context, active: Any?) {
        val names = (active as? List<*>)?.filterIsInstance<String>()?.filter { it in kinds }?.toSet() ?: emptySet()
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putStringSet(ACTIVE, names).apply()
    }

    /**
     * 有効にしている種類のどれかが通知できればtrue。まだ覚えていなければ（期日の通知を足す前の版から更新して
     * アプリを開く前）、確認待ちだけを有効にしているものとして扱う。
     */
    fun allowedAny(context: Context): Boolean {
        val active = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getStringSet(ACTIVE, null) ?: setOf("attention")
        return active.any { allowed(context, it) }
    }

    /** 数時間おきの確認を登録する。登録済みなら間隔を数え直さない。端末を再起動すると消える。登録できたらtrue。 */
    fun schedule(context: Context): Boolean {
        val scheduler = context.getSystemService(JobScheduler::class.java) ?: return false
        if (scheduler.getPendingJob(JOB_ID) != null) return true
        val job = JobInfo.Builder(JOB_ID, ComponentName(context, AttentionJobService::class.java))
            .setPeriodic(PERIOD_MS)
        if (Build.VERSION.SDK_INT >= 26) job.setRequiresBatteryNotLow(true)
        return scheduler.schedule(job.build()) == JobScheduler.RESULT_SUCCESS
    }

    /** 確認の登録と、出ているすべての通知を消す。 */
    fun cancel(context: Context) {
        context.getSystemService(JobScheduler::class.java)?.cancel(JOB_ID)
        for (name in kinds.keys) clear(context, name)
    }

    /** [kind]の通知を出す。keyが前回と同じなら出し直さない。 */
    fun show(context: Context, kind: Any?, key: String, title: String, text: String) {
        require(key.length in 1..64 && title.length in 1..80 && text.length <= 200)
        val k = kindOf(kind)
        if (!allowed(context, kind ?: "attention")) return
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.getString(k.key, null) == key) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= 26) {
            val channel = NotificationChannel(k.channel, context.getString(k.name), k.importance)
            channel.description = context.getString(k.description)
            manager.createNotificationChannel(channel)
        }
        val open = PendingIntent.getActivity(
            context, k.request,
            Intent(context, MainActivity::class.java).setAction(k.action)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, k.channel) else Notification.Builder(context)
        builder.setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(open)
            .setAutoCancel(true)
        manager.notify(k.id, builder.build())
        prefs.edit().putString(k.key, key).apply()
    }

    /**
     * 出ている[kind]の通知を消す。確認待ちは、次に増えたときにまた通知できるよう前回の鍵も消す。
     * 期日は1日に1回までにするため、その日に通知した記録（鍵）は残す。
     */
    fun clear(context: Context, kind: Any? = null) {
        val k = kindOf(kind)
        if (k.channel == "attention") {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(k.key).apply()
        }
        context.getSystemService(NotificationManager::class.java)?.cancel(k.id)
    }
}

/**
 * 数時間おきに呼ばれ、画面のないFlutterエンジンで確認待ちと期日の確認（Dartのattention_check）を動かす。
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
        // お知らせの種類を片方だけ止めているときは、もう片方のために確認する（通知を出すときに種類ごとに確かめる）。
        if (MainActivity.visible || engine != null || !AttentionCheck.allowedAny(this)) return false
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
