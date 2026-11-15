package com.mozuqlab.context_hub_client

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.os.Build
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject

/**
 * アイコン長押しのショートカットとホーム画面ウィジェットから、開く画面を指定して起動するための操作名。
 * 開く画面を選ぶだけで、保存や依頼はアプリの通常の確認を通る。
 */
object LaunchActions {
    private const val PREFIX = "com.mozuqlab.contexthub.action."
    const val CAPTURE = PREFIX + "CAPTURE"
    const val GUIDED = PREFIX + "GUIDED"
    const val NEXT = PREFIX + "NEXT"
    /** 確認待ちの通知から、増えた判断待ちを判断できる画面を開く。 */
    const val ATTENTION = PREFIX + "ATTENTION"

    /**
     * アイコン長押しのショートカットを登録する（Android 7.1以降）。
     * マニフェストに書く固定のショートカットは起動のたびに開いている画面を作り直すため、
     * 書きかけの入力を失わないよう、起動時に登録する形にしている。
     */
    fun publishShortcuts(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) return
        try {
            val manager = context.getSystemService(ShortcutManager::class.java) ?: return
            fun shortcut(id: String, action: String, short: Int, long: Int, icon: Int, rank: Int) =
                ShortcutInfo.Builder(context, id)
                    .setShortLabel(context.getString(short))
                    .setLongLabel(context.getString(long))
                    .setIcon(Icon.createWithResource(context, icon))
                    .setRank(rank)
                    .setIntent(Intent(context, MainActivity::class.java).setAction(action)
                        .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP))
                    .build()
            manager.setDynamicShortcuts(listOf(
                shortcut("capture", CAPTURE, R.string.shortcut_capture_short, R.string.shortcut_capture_long, R.drawable.ic_shortcut_capture, 0),
                shortcut("guided", GUIDED, R.string.shortcut_guided_short, R.string.shortcut_guided_long, R.drawable.ic_shortcut_guided, 1),
                shortcut("next", NEXT, R.string.shortcut_next_short, R.string.shortcut_next_long, R.drawable.ic_shortcut_next, 2),
            ))
        } catch (_: Exception) {
            // 登録できなくても、アプリの通常の操作は使える。
        }
    }

    /** 履歴からの再表示は、前回の操作を繰り返さない。 */
    fun of(intent: Intent?): String? {
        if (intent == null || intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return null
        return when (intent.action) {
            CAPTURE -> "capture"
            GUIDED -> "guided"
            NEXT -> "next"
            ATTENTION -> "attention"
            else -> null
        }
    }
}

/**
 * ホーム画面ウィジェット。アプリが読み込んだ時点の件数（設定すれば次の一手の本文）を出す。
 * Vaultは読まず、アプリから渡された表示用の文字列だけを端末内の設定領域から読む。
 */
class HomeWidgetProvider : AppWidgetProvider() {
    companion object {
        private const val PREFS = "home-widget"
        private const val KEY = "content"
        /** Dart側（homeWidgetMaxBytes）と同じ上限。 */
        const val MAX_BYTES = 4096
        private val LINES = intArrayOf(R.id.widget_line_1, R.id.widget_line_2, R.id.widget_line_3)

        /** 表示する内容を保存し、置かれているウィジェットを描き直す。nullなら内容を消す。 */
        fun store(context: Context, content: String?) {
            if (content != null) {
                require(content.toByteArray(Charsets.UTF_8).size <= MAX_BYTES)
                val json = JSONObject(content)
                require(json.getInt("schema_version") == 1)
            }
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            if (content == null) prefs.remove(KEY) else prefs.putString(KEY, content)
            prefs.apply()
            val manager = AppWidgetManager.getInstance(context) ?: return
            val ids = manager.getAppWidgetIds(ComponentName(context, HomeWidgetProvider::class.java))
            if (ids.isNotEmpty()) render(context, manager, ids, content)
        }

        private fun open(context: Context, action: String, request: Int): PendingIntent = PendingIntent.getActivity(
            context, request,
            Intent(context, MainActivity::class.java).setAction(action)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        private fun render(context: Context, manager: AppWidgetManager, ids: IntArray, content: String?) {
            val views = RemoteViews(context.packageName, R.layout.home_widget)
            var json: JSONObject? = null
            try {
                if (content != null) json = JSONObject(content).takeIf { it.optInt("schema_version") == 1 }
            } catch (_: Exception) {
                json = null
            }
            if (json == null) {
                views.setTextViewText(R.id.widget_title, context.getString(R.string.widget_name))
                views.setTextViewText(R.id.widget_counts, context.getString(R.string.widget_empty))
                views.setViewVisibility(R.id.widget_footer, View.GONE)
                LINES.forEach { views.setViewVisibility(it, View.GONE) }
            } else {
                views.setTextViewText(R.id.widget_title, json.optString("title", context.getString(R.string.widget_name)).take(40))
                views.setTextViewText(R.id.widget_counts, json.optString("counts").take(80))
                val footer = json.optString("footer").take(60)
                views.setTextViewText(R.id.widget_footer, footer)
                views.setViewVisibility(R.id.widget_footer, if (footer.isEmpty()) View.GONE else View.VISIBLE)
                val lines = json.optJSONArray("lines")
                LINES.forEachIndexed { i, id ->
                    val line = if (lines != null && i < lines.length()) lines.optString(i).take(120) else ""
                    views.setTextViewText(id, "・$line")
                    views.setViewVisibility(id, if (line.isEmpty()) View.GONE else View.VISIBLE)
                }
            }
            views.setOnClickPendingIntent(R.id.widget_root, open(context, LaunchActions.NEXT, 1))
            views.setOnClickPendingIntent(R.id.widget_capture, open(context, LaunchActions.CAPTURE, 2))
            manager.updateAppWidget(ids, views)
        }
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val content = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null)
        render(context, manager, ids, content)
    }
}
