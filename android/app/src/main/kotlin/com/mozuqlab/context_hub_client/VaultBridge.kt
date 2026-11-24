package com.mozuqlab.context_hub_client

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract as Docs
import android.provider.OpenableColumns
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.KeyStore
import java.security.MessageDigest
import java.text.Normalizer
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class VaultBridge(
    private val context: Context,
    messenger: BinaryMessenger,
    /** 画面のある起動だけ。アプリを閉じている間の確認ではnullで、フォルダー選択・外部リンク・通知の許可は使えない。 */
    private val activity: Activity? = null,
    /** アプリを閉じている間の確認が終わったことを受け取る。 */
    private val backgroundDone: (() -> Unit)? = null,
    /** ショートカットやウィジェットで選ばれた起動時の操作を1回だけ取り出す。 */
    private val takeLaunchAction: () -> String? = { null },
) {
    private companion object {
        // 読む.md/.jsonの件数、走査する項目（フォルダー・対象外のファイルを含む）の件数、合計バイト数の上限。
        const val MAX_FILES = 20_000
        const val MAX_ENTRIES = 100_000
        /** 更新時刻の粒度（FAT32は2秒）を見込んで、これより新しいファイルは差分読取で再利用しない。 */
        const val RACY_MS = 3_000L
        const val MAX_TOTAL = 64L * 1_048_576
        /** 秘密の暗号化に使うAndroid Keystoreの鍵の名前。鍵は端末の外へ取り出せない。 */
        const val SECRET_ALIAS = "context-hub-secrets"
        /** アプリを閉じている間の確認（画面なし）で使える操作。読むことと通知だけで、書く操作と秘密の読取は受け付けない。 */
        val BACKGROUND_METHODS = setOf("readState", "readSnapshot", "showAttention", "clearAttention", "backgroundDone")
    }
    private val resolver = context.contentResolver
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val folders = setOf("00_inbox", "10_projects", "20_ideas", "30_knowledge", "40_people", "Input", "90_system")
    // Vault直下で読む生成物。共通方針と、本体が生成するふりかえり。
    private val rootFiles = listOf("POLICY.md", "REVIEW.md")
    // 操作journal以外の状態ファイル。保存先の設定、端末に残す書きかけのメモ、選んで深掘りの途中の状態。
    private val nonJournalStates = setOf("settings.json", "drafts.json", "guided.json", "basket.json", "templates.json", "withdrawn.json")
    // 端末に暗号化して置く秘密の名前。選んで深掘りで使うClaudeのAPIキーだけ。
    private val secretNames = setOf("anthropic-api-key")
    private val data = File(context.filesDir, "context-hub").canonicalFile.apply { mkdirs() }
    private val state = File(data, "state").apply { mkdirs() }
    private val secrets = File(data, "secrets").apply { mkdirs() }
    private val sample = File(data, "sample-vault")
    private var picker: MethodChannel.Result? = null
    /** メモに添えるファイルの選択画面の結果を待っている呼び出し。 */
    private var attachmentPicker: MethodChannel.Result? = null
    /** 本人が選択画面で選んだファイル（参照の名前→URI）。選んだURIはアプリの画面がある間だけ読める。 */
    private val picked = ConcurrentHashMap<String, Uri>()
    /** 通知の許可画面の結果を待っている呼び出しと、その通知の種類。 */
    private var permission: MethodChannel.Result? = null
    private var permissionKind: Any? = null
    private val channel = MethodChannel(messenger, "com.mozuqlab.contexthub/vault")
    init {
        channel.setMethodCallHandler { call, result ->
            val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
            if (activity == null && call.method !in BACKGROUND_METHODS) {
                fail(result)
            } else if (call.method == "pickVault") {
                if (picker != null || activity == null) { fail(result); return@setMethodCallHandler }
                picker = result
                try {
                    activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION), 8831)
                } catch (_: Exception) { picker = null; fail(result) }
            } else if (call.method == "pickAttachment") {
                // メモに添えるファイルを選ぶ。Vaultには触れず、名前・大きさと参照だけを返す。
                if (attachmentPicker != null || activity == null) { fail(result); return@setMethodCallHandler }
                attachmentPicker = result
                try {
                    activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT)
                        .addCategory(Intent.CATEGORY_OPENABLE).setType("*/*"), 8832)
                } catch (_: Exception) { attachmentPicker = null; fail(result) }
            } else if (call.method == "openVaultFile") {
                // Vaultのファイル（05_files）を端末の既定のアプリで開く。開くアプリへは、そのファイルを読む権限だけを一時的に渡す。
                // フォルダーをたどる問い合わせは、ほかのVaultの操作と同じく読取用のスレッドで行い、画面を止めない。
                executor.execute {
                    try {
                        val handle = args["handle"] as String
                        require(handle != "sample")
                        val file = vaultFile(tree(handle), args["path"] as String)
                        val mime = resolver.getType(file.uri)?.takeIf { it.isNotEmpty() } ?: "application/octet-stream"
                        // インストーラーなど、開くとプログラムとして動く種類は開かない（Dartでも名前で断る）。
                        if (mime == "application/vnd.android.package-archive") throw AttachmentFailure("file_launchable")
                        main.post {
                            try {
                                requireNotNull(activity).startActivity(Intent(Intent.ACTION_VIEW)
                                    .setDataAndType(file.uri, mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                                result.success(null)
                            } catch (_: android.content.ActivityNotFoundException) { result.error("file_no_app", null, null) }
                            catch (_: Exception) { fail(result) }
                        }
                    } catch (e: Exception) { main.post { failWith(result, e) } }
                }
            } else if (call.method == "openExternal") {
                try {
                    val uri = Uri.parse(args["url"] as String)
                    require(uri.scheme in listOf("http", "https") && !uri.host.isNullOrEmpty())
                    requireNotNull(activity).startActivity(Intent(Intent.ACTION_VIEW, uri))
                    result.success(null)
                } catch (_: Exception) { fail(result) }
            } else if (call.method == "addToCalendar") {
                // 端末のカレンダーの予定作成画面を開くだけ。保存するかは本人が決め、アプリはカレンダーの権限を取らない。
                try {
                    val date = Regex("^(\\d{4})-(\\d{2})-(\\d{2})$").matchEntire(args["date"] as String)!!.groupValues
                    // 終日の予定は、その日の0時（UTC）から翌日の0時（UTC）として渡す。
                    val begin = java.util.Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC")).apply {
                        clear(); set(date[1].toInt(), date[2].toInt() - 1, date[3].toInt())
                    }.timeInMillis
                    requireNotNull(activity).startActivity(Intent(Intent.ACTION_INSERT)
                        .setData(android.provider.CalendarContract.Events.CONTENT_URI)
                        .putExtra(android.provider.CalendarContract.EXTRA_EVENT_ALL_DAY, true)
                        .putExtra(android.provider.CalendarContract.EXTRA_EVENT_BEGIN_TIME, begin)
                        .putExtra(android.provider.CalendarContract.EXTRA_EVENT_END_TIME, begin + 86_400_000L)
                        .putExtra(android.provider.CalendarContract.Events.TITLE, args["title"] as String)
                        .putExtra(android.provider.CalendarContract.Events.DESCRIPTION, args["description"] as String)
                        .putExtra(android.provider.CalendarContract.Events.AVAILABILITY, android.provider.CalendarContract.Events.AVAILABILITY_FREE))
                    result.success(null)
                } catch (_: Exception) { fail(result) }
            } else if (call.method == "takeLaunchAction") {
                result.success(takeLaunchAction())
            } else if (call.method == "updateHomeWidget") {
                // 表示用の短い文字列を端末内に置くだけで、Vaultには触れない。
                try {
                    HomeWidgetProvider.store(context.applicationContext, args["content"] as String?)
                    result.success(null)
                } catch (_: Exception) { fail(result) }
            } else if (call.method == "attentionNotifications") {
                // 数時間おきの確認の有効・無効（確認待ちと期日で共有）。有効にできた（kindの通知が許可されている）ときだけtrueを返す。
                try {
                    val app = context.applicationContext
                    val kind = args["kind"] ?: "attention"
                    AttentionCheck.setActive(app, if (args["enabled"] == true) args["active"] ?: listOf(kind) else emptyList<String>())
                    if (args["enabled"] != true) {
                        AttentionCheck.cancel(app)
                        result.success(false)
                    } else if (AttentionCheck.allowed(app, kind)) {
                        result.success(AttentionCheck.schedule(app))
                    } else if (!AttentionCheck.allowed(app)) {
                        // 許可がない間は、通知できない確認を続けない。
                        AttentionCheck.cancel(app)
                        if (args["request"] == true && activity != null && permission == null &&
                            Build.VERSION.SDK_INT >= 33 &&
                            activity.checkSelfPermission(AttentionCheck.PERMISSION) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                            // 本人が設定を入れたときだけ、端末の許可画面を出す。
                            permission = result
                            permissionKind = kind
                            activity.requestPermissions(arrayOf(AttentionCheck.PERMISSION), AttentionCheck.PERMISSION_REQUEST)
                        } else result.success(false)
                    } else {
                        // アプリの通知は許可されているが、このお知らせの種類だけが端末の設定で止められている。
                        // 有効にしているもう一方の種類が通知できれば確認を続け、どれも通知できなければ確認を止める。
                        if (AttentionCheck.allowedAny(app)) AttentionCheck.schedule(app) else AttentionCheck.cancel(app)
                        result.success(false)
                    }
                } catch (_: Exception) {
                    if (permission === result) permission = null
                    fail(result)
                }
            } else if (call.method == "showAttention") {
                // 件数と種類だけの短い文を通知に出す。Vaultには触れない。
                try {
                    // 確認の途中でアプリの画面が開いたら、アプリが件数を出すので通知しない。
                    if (activity != null || !MainActivity.visible) {
                        AttentionCheck.show(context.applicationContext, args["kind"], args["key"] as String, args["title"] as String, args["text"] as String)
                    }
                    result.success(null)
                } catch (_: Exception) { fail(result) }
            } else if (call.method == "clearAttention") {
                try {
                    AttentionCheck.clear(context.applicationContext, args["kind"])
                    result.success(null)
                } catch (_: Exception) { fail(result) }
            } else if (call.method == "backgroundDone") {
                result.success(null)
                backgroundDone?.invoke()
            } else executor.execute {
                try {
                    val value = invoke(call.method, args)
                    main.post { result.success(value) }
                } catch (e: Exception) {
                    if (context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0) {
                        android.util.Log.w("ContextHub", e.javaClass.simpleName + ": " + e.stackTrace.take(3).joinToString())
                    }
                    main.post { failWith(result, e) }
                }
            }
        }
    }
    /** アプリを閉じている間の確認が終わったら、読取用のスレッドを止める。 */
    fun close() { executor.shutdown() }
    /** 通知の許可画面の結果。許可されたら数時間おきの確認を登録する。 */
    fun permissionResult(request: Int): Boolean {
        if (request != AttentionCheck.PERMISSION_REQUEST) return false
        val result = permission ?: return true
        val kind = permissionKind ?: "attention"
        permission = null
        permissionKind = null
        try {
            val app = context.applicationContext
            result.success(AttentionCheck.allowed(app, kind) && AttentionCheck.schedule(app))
        } catch (_: Exception) { fail(result) }
        return true
    }
    /** アプリを開いたまま新しい起動時の操作が届いたことをFlutter側へ知らせる。 */
    fun notifyLaunchAction() = channel.invokeMethod("launchAction", null)
    /** ファイルを添える・開く操作の理由（Dartが本人向けの説明にする。Vaultの選び直しを促さない）。 */
    private class AttachmentFailure(val code: String) : Exception(code)
    private fun failWith(result: MethodChannel.Result, e: Exception) =
        if (e is AttachmentFailure) result.error(e.code, null, null) else fail(result)
    private fun fail(result: MethodChannel.Result) = result.error("vault_access",
        "Vaultへアクセスできません。ローカルの選択フォルダーと権限を確認し、必要なら再選択してください。", null)
    fun activityResult(request: Int, code: Int, intent: Intent?): Boolean {
        if (request == 8832) return attachmentResult(code, intent)
        if (request != 8831) return false
        val result = picker ?: return true
        picker = null
        if (code != Activity.RESULT_OK || intent?.data == null) { result.success(null); return true }
        try {
            val uri = intent.data!!
            require(uri.authority == "com.android.externalstorage.documents" && Docs.isTreeUri(uri))
            val flags = intent.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            require(flags == Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            resolver.takePersistableUriPermission(uri, flags)
            val root = Docs.buildDocumentUriUsingTree(uri, Docs.getTreeDocumentId(uri))
            result.success(mapOf("handle" to uri.toString(), "name" to info(root).name))
        } catch (_: Exception) { fail(result) }
        return true
    }
    /** ファイルの選択画面の結果。名前は合成済みの文字（NFC）にそろえ、大きさが分からなければ失敗にする。 */
    private fun attachmentResult(code: Int, intent: Intent?): Boolean {
        val result = attachmentPicker ?: return true
        attachmentPicker = null
        val uri = intent?.data
        if (code != Activity.RESULT_OK || uri == null) { result.success(null); return true }
        // 名前と大きさの問い合わせは、クラウドのproviderでは時間がかかるため読取用のスレッドで行う。
        executor.execute {
            try {
                val (name, size) = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null).use { c ->
                    require(c != null && c.moveToFirst())
                    Pair(if (c.isNull(0)) null else c.getString(0), if (c.isNull(1)) null else c.getLong(1))
                }
                val bytes = size ?: (try { resolver.openAssetFileDescriptor(uri, "r")?.use { it.length }?.takeIf { it >= 0 } } catch (_: Exception) { null })
                    ?: throw AttachmentFailure("attachment_unreadable")
                val token = UUID.randomUUID().toString()
                picked[token] = uri
                main.post { result.success(mapOf("token" to token, "name" to Normalizer.normalize(name ?: "file", Normalizer.Form.NFC), "bytes" to bytes)) }
            } catch (e: Exception) { main.post { failWith(result, e) } }
        }
        return true
    }
    /** 選んだファイルを読む。読めなければ（クラウドにだけある・権限が切れたなど）理由付きで失敗にする。 */
    private fun openSource(uri: Uri): InputStream =
        (try { resolver.openInputStream(uri) } catch (_: Exception) { null }) ?: throw AttachmentFailure("attachment_unreadable")
    /** 名前の子フォルダー。なければ作る（同じ名前の別の種類があれば失敗）。 */
    private fun childDir(parent: Uri, name: String): Entry {
        var dir = children(parent).firstOrNull { it.name == name }
        if (dir == null) {
            val uri = Docs.createDocument(resolver, parent, Docs.Document.MIME_TYPE_DIR, name) ?: error("作成不可")
            dir = info(uri); require(dir.name == name)
        }
        require(dir.dir)
        return dir
    }
    /** 読みながら大きさとSHA-256（16進の小文字）を求める。上限を超えれば失敗。 */
    private fun digestOf(stream: InputStream, limit: Long): Pair<Long, String> = stream.use {
        val digest = MessageDigest.getInstance("SHA-256"); val buffer = ByteArray(1 shl 20); var total = 0L
        while (true) {
            val n = it.read(buffer)
            if (n < 0) break
            total += n; if (total > limit) throw AttachmentFailure("attachment_too_large")
            digest.update(buffer, 0, n)
        }
        Pair(total, digest.digest().joinToString("") { b -> "%02x".format(b.toInt() and 0xff) })
    }
    /**
     * 選んだファイルをInput/files/<受付ID>へ写す。一時ファイルへ書いてfsyncし、まだない名前へrenameで公開してから読み直す。
     * 同じ受付IDのファイルが既にあれば（保存の途中で止まった後の再試行）、内容が同じときだけ使う。
     */
    private fun stage(root: Uri, id: String, source: Uri, limit: Long): Map<String, Any> {
        val files = childDir(childDir(root, "Input").uri, "files")
        val existing = children(files.uri).firstOrNull { it.name == id }
        if (existing != null) {
            // 同じ受付IDに別の内容が既にある（前に写しかけた別のファイル）。Dartは別の操作IDで保存し直す。
            val now = digestOf(openSource(source), limit)
            val old = if (existing.dir) null else try { digestOf(resolver.openInputStream(existing.uri) ?: error("読取不可"), limit) } catch (_: Exception) { null }
            if (old != now) throw AttachmentFailure("attachment_conflict")
            return mapOf("bytes" to now.first, "sha256" to now.second)
        }
        val temp = Docs.createDocument(resolver, files.uri, "application/octet-stream", ".ctx-${UUID.randomUUID()}.tmp") ?: error("作成不可")
        val digest = MessageDigest.getInstance("SHA-256"); var total = 0L
        try {
            val pfd = resolver.openFileDescriptor(temp, "w") ?: error("書込不可")
            android.os.ParcelFileDescriptor.AutoCloseOutputStream(pfd).use { out ->
                openSource(source).use { input ->
                    val buffer = ByteArray(1 shl 20)
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        total += n; if (total > limit) throw AttachmentFailure("attachment_too_large")
                        digest.update(buffer, 0, n); out.write(buffer, 0, n)
                    }
                }
                out.flush(); Os.fsync(pfd.fileDescriptor)
            }
            require(children(files.uri).none { it.name == id })
        } catch (e: Exception) {
            // 公開する前の失敗では、書きかけの一時ファイルを消す。
            try { Docs.deleteDocument(resolver, temp) } catch (_: Exception) {}
            throw e
        }
        val hash = digest.digest().joinToString("") { b -> "%02x".format(b.toInt() and 0xff) }
        // 公開の結果が分からないときは一時ファイルを残す（受付IDのファイルが既にあれば、再試行で内容を確かめる）。
        val renamed = Docs.renameDocument(resolver, temp, id) ?: error("確定不可")
        val published = info(renamed)
        if (published.name != id || published.dir) {
            // 同じ名前が同時にでき、providerが別の名前（「REQ-… (1)」など）にした。残すと依頼のないファイルになるため消す。
            try { Docs.deleteDocument(resolver, renamed) } catch (_: Exception) {}
            throw AttachmentFailure("attachment_conflict")
        }
        require(digestOf(resolver.openInputStream(renamed) ?: error("読取不可"), limit) == Pair(total, hash))
        return mapOf("bytes" to total, "sha256" to hash)
    }
    /**
     * この端末が書いた依頼（Input/<受付ID>.md）を取り下げる。内容のSHA-256が書いたときのまま（expected）のときだけ、
     * 依頼を消してから、添えたファイル（Input/files/<受付ID>）も消す（先に添付を消すと、受付が添付なしとして断るため）。
     * 消したらwithdrawn、依頼がなければmissing、内容が違えば何も消さずにchangedを返す。
     */
    private fun withdraw(handle: String, id: String, expected: String): String {
        val name = "$id.md"
        if (handle == "sample") {
            val input = safe(File(sample, "Input"))
            if (!input.isDirectory) return "missing"
            val file = safe(File(input, name))
            if (!file.exists()) return "missing"
            require(file.isFile)
            if (digestOf(file.inputStream(), 1L shl 20).second != expected) return "changed"
            // 本体が受付を始めた依頼（停止回復の記録がある）は、ファイルを消しても記録の写しから受け付けるので消さない。
            if (File(sample, "90_system/intake/pending/$id.json").exists()) return "started"
            require(file.delete() || !file.exists())
            // 依頼を消した後の失敗（同期・添付の削除）は取り下げを止めない。残った添付は本体のdoctorが示す。
            runCatching {
                syncDir(input)
                val attachment = safe(File(File(input, "files"), id))
                if (attachment.isFile && attachment.delete()) syncDir(attachment.parentFile!!)
            }
            return "withdrawn"
        }
        val root = tree(handle)
        val input = children(root).firstOrNull { it.name == "Input" } ?: return "missing"
        require(input.dir)
        val file = children(input.uri).firstOrNull { it.name == name } ?: return "missing"
        require(!file.dir)
        val actual = digestOf(resolver.openInputStream(file.uri) ?: error("読取不可"), 1L shl 20).second
        if (actual != expected) return "changed"
        // 本体が受付を始めた依頼（停止回復の記録がある）は、ファイルを消しても記録の写しから受け付けるので消さない。
        var dir: Entry? = Entry(root, "", true)
        for (part in listOf("90_system", "intake", "pending")) dir = dir?.let { d -> children(d.uri).firstOrNull { it.name == part && it.dir } }
        if (dir != null && children(dir.uri).any { it.name == "$id.json" }) return "started"
        require(Docs.deleteDocument(resolver, file.uri))
        // 依頼を消した後の失敗（添付の削除）は取り下げを止めない。残った添付は本体のdoctorが示す。
        runCatching {
            val files = children(input.uri).firstOrNull { it.name == "files" && it.dir }
            val attachment = files?.let { d -> children(d.uri).firstOrNull { it.name == id && !it.dir } }
            if (attachment != null) Docs.deleteDocument(resolver, attachment.uri)
        }
        return "withdrawn"
    }
    /** Vault内のメモに添えたファイル（05_files/<年-月>/<キー>/<名前>）。名前で1段ずつたどる。 */
    private fun vaultFile(root: Uri, path: String): Entry {
        val parts = path.split('/')
        require(parts.size == 4 && parts[0] == "05_files" && parts[1].matches(Regex("[0-9]{4}-(0[1-9]|1[0-2])")) &&
            parts[2].matches(Regex("[0-9a-f]{24}")) && parts[3].isNotEmpty() && !parts[3].startsWith('.') && !path.contains('\\'))
        var current = Entry(root, "", true)
        for ((index, part) in parts.withIndex()) {
            current = children(current.uri).firstOrNull { it.name == part } ?: throw AttachmentFailure("file_missing")
            require(if (index < parts.size - 1) current.dir else !current.dir)
        }
        return current
    }
    // stampは更新時刻（ミリ秒）と大きさ。providerが返さない場合はnullで、その場合は毎回読む。
    private data class Entry(val uri: Uri, val name: String, val dir: Boolean, val stamp: String? = null, val size: Long? = null)
    private fun info(uri: Uri): Entry {
        resolver.query(uri, arrayOf(Docs.Document.COLUMN_DISPLAY_NAME, Docs.Document.COLUMN_MIME_TYPE), null, null, null).use { c ->
            require(c != null && c.moveToFirst())
            return Entry(uri, c.getString(0), c.getString(1) == Docs.Document.MIME_TYPE_DIR)
        }
    }
    /** フォルダーの項目数が読取の上限を超えた。 */
    private class EntryLimit : Exception()
    private fun children(uri: Uri, limit: Int = MAX_ENTRIES): List<Entry> {
        val list = ArrayList<Entry>()
        resolver.query(Docs.buildChildDocumentsUriUsingTree(uri, Docs.getDocumentId(uri)),
            arrayOf(Docs.Document.COLUMN_DOCUMENT_ID, Docs.Document.COLUMN_DISPLAY_NAME, Docs.Document.COLUMN_MIME_TYPE,
                Docs.Document.COLUMN_LAST_MODIFIED, Docs.Document.COLUMN_SIZE), null, null, null).use { c ->
            require(c != null)
            while (c.moveToNext()) {
                if (list.size >= limit) throw EntryLimit()
                val name = c.getString(1)
                require(name.isNotEmpty() && !name.contains('/') && !name.contains('\\'))
                val modified = if (c.isNull(3)) 0L else c.getLong(3)
                val size = if (c.isNull(4)) null else c.getLong(4)
                val stamp = if (modified > 0 && size != null) "$modified:$size" else null
                list.add(Entry(Docs.buildDocumentUriUsingTree(uri, c.getString(0)), name, c.getString(2) == Docs.Document.MIME_TYPE_DIR, stamp, size))
            }
        }
        require(list.map { it.name }.distinct().size == list.size)
        return list
    }
    private fun tree(handle: String): Uri {
        val uri = Uri.parse(handle)
        require(uri.scheme == "content" && uri.authority == "com.android.externalstorage.documents" && Docs.isTreeUri(uri))
        require(resolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission && it.isWritePermission })
        return Docs.buildDocumentUriUsingTree(uri, Docs.getTreeDocumentId(uri))
    }
    private fun text(stream: InputStream, limit: Int = 1_048_576): String = stream.use {
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(16384)
        while (true) {
            val n = it.read(buffer)
            if (n < 0) break
            require(out.size() + n <= limit)
            out.write(buffer, 0, n)
        }
        Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(out.toByteArray())).toString()
    }
    private fun safe(file: File): File {
        require(file.absolutePath == file.canonicalPath && (file.canonicalPath == data.path || file.canonicalPath.startsWith(data.path + "/")))
        return file
    }
    private fun stateFile(name: String): File {
        require(name in nonJournalStates || name.matches(Regex("[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\\.json")))
        return safe(File(state, name))
    }
    private fun secretFile(name: String): File {
        require(name in secretNames)
        return safe(File(secrets, "$name.sealed"))
    }
    /** 秘密を暗号化するAES-GCMの鍵。Android Keystoreに置き、初回だけ作る。 */
    private fun secretKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(SECRET_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(SECRET_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return generator.generateKey()
    }
    private fun syncDir(dir: File) {
        val fd = Os.open(safe(dir).path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW, 0)
        try { require(OsConstants.S_ISDIR(Os.fstat(fd).st_mode)); Os.fsync(fd) } finally { Os.close(fd) }
    }
    private fun writeFile(file: File, raw: String, exclusive: Boolean) {
        safe(file); safe(file.parentFile!!)
        if (exclusive) {
            // 最終名へ直接書くと、作成とfsyncの間で止まったときに空や途中のjournalが残る。
            // 一時ファイル（名前が.で始まり、journalの一覧に出ない）へO_EXCLで書いてfsyncし、
            // まだない最終名へrenameで公開する。fsync完了後だけ呼出元を進める。
            // Androidのapp-dataではhardlinkが拒否されるため、存在の確認とrenameの間の排他は、
            // この窓口の処理が1本のスレッド（executor）で順に進むことに頼る。
            // 書く操作を受け付けるのは画面のある窓口だけで、ほかのプロセスはこの領域へ書かない。
            val temp = File(file.parentFile, ".ctx-${UUID.randomUUID()}.tmp")
            val fd = Os.open(temp.path, OsConstants.O_WRONLY or OsConstants.O_CREAT or
                OsConstants.O_EXCL or OsConstants.O_NOFOLLOW, 384)
            try {
                FileOutputStream(fd).use { it.write(raw.toByteArray(Charsets.UTF_8)); it.fd.sync() }
                val exists = try {
                    Os.lstat(file.path); true
                } catch (e: ErrnoException) {
                    if (e.errno != OsConstants.ENOENT) throw e
                    false
                }
                require(!exists)
                Os.rename(temp.path, file.path)
                syncDir(file.parentFile!!)
            } finally { temp.delete() }
            return
        }
        val temp = File(file.parentFile, ".ctx-${UUID.randomUUID()}.tmp")
        require(temp.createNewFile())
        try {
            FileOutputStream(temp).use { it.write(raw.toByteArray(Charsets.UTF_8)); it.fd.sync() }
            Os.rename(temp.path, file.path)
            syncDir(file.parentFile!!)
        } finally { temp.delete() }
    }
    /**
     * Vaultを読む。skipに挙げたパス（フォルダーまたはファイル）は数えず読まない。
     * knownに前回のstamp（更新時刻と大きさ）が一致するファイルは本文を読まずunchangedに返す。stampは読む前に取る。
     * 更新時刻が読取開始の直前（RACY_MS以内）のファイルはstampを返さない。時刻の粒度が粗い保存先では、
     * 同じ時刻のうちに同じ大きさで書き換えられても区別できないため、次回も本文を読み直す。
     */
    private fun snapshot(handle: String, skip: Set<String> = emptySet(), known: Map<String, String> = emptyMap()): Map<String, Any> {
        val files = linkedMapOf<String, String>(); val warnings = arrayListOf<String>()
        val unchanged = arrayListOf<String>(); val stamps = linkedMapOf<String, String>()
        var entries = 0; var count = 0; var total = 0L; var recognized = false
        val started = System.currentTimeMillis()
        val limitWarning = "読取の上限（ファイル${MAX_FILES}件・合計64MB）に達したため、"
        fun over() = entries > MAX_ENTRIES || count > MAX_FILES || total > MAX_TOTAL
        fun add(path: String, stamp: String?, size: Long?, read: () -> String) {
            require(++count <= MAX_FILES)
            if (stamp != null && size != null && known[path] == stamp) {
                total += size; require(total <= MAX_TOTAL)
                unchanged.add(path); stamps[path] = stamp
                return
            }
            try {
                val raw = read(); total += raw.toByteArray(Charsets.UTF_8).size
                require(total <= MAX_TOTAL)
                files[path] = raw
                val modified = stamp?.substringBefore(':')?.toLongOrNull()
                if (stamp != null && modified != null && modified < started - RACY_MS) stamps[path] = stamp
            } catch (_: Exception) { warnings.add("読取できないファイル: $path") }
            require(total <= MAX_TOTAL)
        }
        fun local(dir: File, prefix: String, depth: Int) {
            if (depth > 12) { warnings.add("深さの上限に達しました。"); return }
            for (file in safe(dir).listFiles() ?: error("読取不可")) {
                require(++entries <= MAX_ENTRIES)
                if (file.name.startsWith('.') || file.extension == "tmp") continue
                val path = "$prefix/${file.name}"
                if (path in skip) continue
                if (file.canonicalPath != file.absolutePath) { warnings.add("symlinkを除外: $path"); continue }
                if (file.isDirectory) local(file, path, depth + 1)
                else if (file.extension in listOf("md", "json")) {
                    val size = file.length(); val modified = file.lastModified()
                    add(path, if (modified > 0) "$modified:$size" else null, size) { text(safe(file).inputStream()) }
                }
            }
        }
        fun visit(dir: Uri, prefix: String, depth: Int) {
            if (depth > 12) { warnings.add("深さの上限に達しました。"); return }
            // 1つのフォルダーの項目数が上限を超えた場合も、読取の上限として扱う。
            val list = try { children(dir, MAX_ENTRIES - entries) } catch (e: EntryLimit) { entries = MAX_ENTRIES + 1; throw e }
            for (e in list) {
                require(++entries <= MAX_ENTRIES)
                if (e.name.startsWith('.') || e.name.endsWith(".tmp")) continue
                val path = "$prefix/${e.name}"
                if (path in skip) continue
                if (e.dir) visit(e.uri, path, depth + 1)
                else if (e.name.substringAfterLast('.') in listOf("md", "json")) add(path, e.stamp, e.size) {
                    text(resolver.openInputStream(e.uri) ?: error("読取不可"))
                }
            }
        }
        fun interrupted(name: String): Boolean {
            if (over()) { warnings.add(limitWarning + name + "の一部を読めませんでした。"); return true }
            warnings.add("フォルダーの読取を中断: $name"); return false
        }
        if (handle == "sample") {
            for (name in folders) {
                val dir = File(sample, name)
                if (!dir.exists()) continue
                try { require(dir.isDirectory); recognized = true; local(dir, name, 1) }
                catch (_: Exception) { if (interrupted(name)) break }
            }
            for (name in rootFiles) {
                val file = File(sample, name)
                if (!file.exists()) continue
                if (count + 1 > MAX_FILES) warnings.add(limitWarning + name + "を読めませんでした。")
                else try { add(name, null, null) { text(safe(file).inputStream()) } }
                catch (_: Exception) { warnings.add(limitWarning + name + "を読めませんでした。") }
            }
        } else {
            val top = children(tree(handle))
            for (e in top) {
                if (e.name !in folders) continue
                try { require(e.dir); recognized = true; visit(e.uri, e.name, 1) }
                catch (_: Exception) { if (interrupted(e.name)) break }
            }
            // macOSと同じく、フォルダーの読取が上限で止まっても直下の方針・ふりかえりは読む。
            for (e in top) {
                if (e.name !in rootFiles) continue
                if (count + 1 > MAX_FILES) warnings.add(limitWarning + e.name + "を読めませんでした。")
                else if (e.dir) warnings.add("${e.name}が通常ファイルではありません")
                else try { add(e.name, null, null) { text(resolver.openInputStream(e.uri) ?: error("読取不可")) } }
                catch (_: Exception) { warnings.add(limitWarning + e.name + "を読めませんでした。") }
            }
        }
        return mapOf("files" to files, "warnings" to warnings, "recognized" to recognized, "unchanged" to unchanged, "stamps" to stamps)
    }
    private fun invoke(method: String, args: Map<*, *>): Any? {
        when (method) {
            "sampleVault" -> {
                val files = args["files"] as Map<*, *>
                require(files.size <= 5000)
                require(files.values.sumOf { (it as String).toByteArray(Charsets.UTF_8).size.toLong() } <= 64L * 1_048_576)
                if (!sample.exists()) {
                    val staging = File(data, ".sample-${UUID.randomUUID()}.tmp")
                    require(staging.mkdir())
                    folders.forEach { require(File(staging, it).mkdir()) }
                    files.forEach { (key, value) ->
                        val path = key as String; val raw = value as String; val parts = path.split('/')
                        if (path !in rootFiles && (parts.size < 2 || parts.size > 13 || parts[0] !in folders)) return@forEach
                        require(parts.all { it.isNotEmpty() && !it.startsWith('.') && !it.contains('\\') })
                        val file = safe(File(staging, path)); require(raw.toByteArray().size <= 1_048_576)
                        file.parentFile!!.mkdirs(); writeFile(file, raw, true)
                    }
                    require(!sample.exists())
                    Os.rename(staging.path, sample.path); syncDir(data)
                }
                safe(sample)
                return mapOf("handle" to "sample", "name" to "架空サンプル")
            }
            "listJournals" -> return (state.list() ?: error("読取不可")).filter { it !in nonJournalStates && !it.startsWith('.') }
            "readSecret" -> {
                val file = secretFile(args["name"] as String)
                if (!file.exists()) return null
                // 先頭12バイトがGCMのIV、残りが暗号文と認証タグ。
                val sealed = Base64.decode(text(file.inputStream(), 16384), Base64.NO_WRAP)
                require(sealed.size > 12)
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, sealed, 0, 12))
                return String(cipher.doFinal(sealed, 12, sealed.size - 12), Charsets.UTF_8)
            }
            "writeSecret" -> {
                val file = secretFile(args["name"] as String)
                val value = args["value"] as String
                require(value.isNotEmpty() && value.toByteArray(Charsets.UTF_8).size <= 4096)
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.ENCRYPT_MODE, secretKey())
                val iv = cipher.iv
                require(iv.size == 12)
                val sealed = iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
                writeFile(file, Base64.encodeToString(sealed, Base64.NO_WRAP), false)
                return null
            }
            "deleteSecret" -> {
                val file = secretFile(args["name"] as String)
                if (file.exists()) require(file.delete())
                syncDir(secrets)
                return null
            }
            "readState" -> {
                val file = stateFile(args["name"] as String)
                return if (file.exists()) text(file.inputStream(), 65536) else null
            }
            "writeState" -> {
                val raw = args["raw"] as String; require(raw.toByteArray().size <= 65536)
                writeFile(stateFile(args["name"] as String), raw, args["exclusive"] == true); return null
            }
        }
        val handle = args["handle"] as String
        if (method == "readSnapshot") {
            val skip = (args["skip"] as? List<*>)?.filterIsInstance<String>()?.toSet() ?: emptySet()
            val known = (args["known"] as? Map<*, *>)?.entries
                ?.mapNotNull { (k, v) -> if (k is String && v is String) k to v else null }?.toMap() ?: emptyMap()
            return snapshot(handle, skip, known)
        }
        if (method == "stageAttachment") {
            require(handle != "sample")
            val id = args["requestId"] as String
            require(id.matches(Regex("REQ-[a-f0-9]{32}")))
            val source = picked[args["token"] as String] ?: throw AttachmentFailure("attachment_lost")
            val limit = (args["maxBytes"] as Number).toLong()
            require(limit > 0)
            return stage(tree(handle), id, source, limit)
        }
        if (method == "withdrawRequest") {
            val id = args["requestId"] as String
            val expected = args["sha256"] as String
            require(id.matches(Regex("REQ-[a-f0-9]{32}")) && expected.matches(Regex("[a-f0-9]{64}")))
            return withdraw(handle, id, expected)
        }
        require(method in listOf("readRequest", "writeRequest"))
        val id = args["requestId"] as String
        require(id.matches(Regex("REQ-[a-f0-9]{32}")))
        val name = "$id.md"
        if (handle == "sample") {
            val input = safe(File(sample, "Input")); require(input.isDirectory)
            val file = safe(File(input, name))
            if (method == "readRequest") return if (file.exists()) text(file.inputStream()) else null
            val raw = args["raw"] as String; require(raw.toByteArray().size <= 40192)
            writeFile(file, raw, true); require(text(file.inputStream()) == raw); return null
        }
        val root = tree(handle)
        var input = children(root).firstOrNull { it.name == "Input" }
        if (method == "readRequest" && input == null) return null
        if (input == null) {
            val uri = Docs.createDocument(resolver, root, Docs.Document.MIME_TYPE_DIR, "Input") ?: error("作成不可")
            input = info(uri); require(input.name == "Input" && input.dir)
        }
        require(input.dir)
        val existing = children(input.uri).firstOrNull { it.name == name }
        if (method == "readRequest") return existing?.let { require(!it.dir); text(resolver.openInputStream(it.uri)!!) }
        require(existing == null)
        val raw = args["raw"] as String; require(raw.toByteArray().size <= 40192)
        val temp = Docs.createDocument(resolver, input.uri, "application/octet-stream", ".ctx-${UUID.randomUUID()}.tmp") ?: error("作成不可")
        // 一時ファイルは不明な結果でも残す。REQの再発行は行わない。
        val pfd = resolver.openFileDescriptor(temp, "w") ?: error("書込不可")
        android.os.ParcelFileDescriptor.AutoCloseOutputStream(pfd).use {
            it.write(raw.toByteArray(Charsets.UTF_8)); it.flush(); Os.fsync(pfd.fileDescriptor)
        }
        require(children(input.uri).none { it.name == name })
        val renamed = Docs.renameDocument(resolver, temp, name) ?: error("確定不可")
        val published = info(renamed)
        require(published.name == name && !published.dir)
        val saved = text(resolver.openInputStream(renamed)!!)
        require(MessageDigest.getInstance("SHA-256").digest(saved.toByteArray()).contentEquals(
            MessageDigest.getInstance("SHA-256").digest(raw.toByteArray())))
        return null
    }
}
