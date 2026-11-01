package com.mozuqlab.context_hub_client

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract as Docs
import android.system.Os
import android.system.OsConstants
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors

class VaultBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val resolver = activity.contentResolver
    private val executor = Executors.newSingleThreadExecutor()
    private val folders = setOf("00_inbox", "10_projects", "20_ideas", "30_knowledge", "Input", "90_system")
    private val data = File(activity.filesDir, "context-hub").canonicalFile.apply { mkdirs() }
    private val state = File(data, "state").apply { mkdirs() }
    private val sample = File(data, "sample-vault")
    private var picker: MethodChannel.Result? = null
    private val channel = MethodChannel(messenger, "com.mozuqlab.contexthub/vault")
    init {
        channel.setMethodCallHandler { call, result ->
            val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
            if (call.method == "pickVault") {
                if (picker != null) { fail(result); return@setMethodCallHandler }
                picker = result
                try {
                    activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION), 8831)
                } catch (_: Exception) { picker = null; fail(result) }
            } else if (call.method == "openExternal") {
                try {
                    val uri = Uri.parse(args["url"] as String)
                    require(uri.scheme in listOf("http", "https") && !uri.host.isNullOrEmpty())
                    activity.startActivity(Intent(Intent.ACTION_VIEW, uri))
                    result.success(null)
                } catch (_: Exception) { fail(result) }
            } else executor.execute {
                try {
                    val value = invoke(call.method, args)
                    activity.runOnUiThread { result.success(value) }
                } catch (e: Exception) {
                    if (activity.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0) {
                        android.util.Log.w("ContextHub", e.javaClass.simpleName + ": " + e.stackTrace.take(3).joinToString())
                    }
                    activity.runOnUiThread { fail(result) }
                }
            }
        }
    }
    private fun fail(result: MethodChannel.Result) = result.error("vault_access",
        "Vaultへアクセスできません。ローカルの選択フォルダーと権限を確認し、必要なら再選択してください。", null)
    fun activityResult(request: Int, code: Int, intent: Intent?): Boolean {
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
    private data class Entry(val uri: Uri, val name: String, val dir: Boolean)
    private fun info(uri: Uri): Entry {
        resolver.query(uri, arrayOf(Docs.Document.COLUMN_DISPLAY_NAME, Docs.Document.COLUMN_MIME_TYPE), null, null, null).use { c ->
            require(c != null && c.moveToFirst())
            return Entry(uri, c.getString(0), c.getString(1) == Docs.Document.MIME_TYPE_DIR)
        }
    }
    private fun children(uri: Uri, limit: Int = 5000): List<Entry> {
        val list = ArrayList<Entry>()
        resolver.query(Docs.buildChildDocumentsUriUsingTree(uri, Docs.getDocumentId(uri)),
            arrayOf(Docs.Document.COLUMN_DOCUMENT_ID, Docs.Document.COLUMN_DISPLAY_NAME, Docs.Document.COLUMN_MIME_TYPE), null, null, null).use { c ->
            require(c != null)
            while (c.moveToNext()) {
                require(list.size < limit)
                val name = c.getString(1)
                require(name.isNotEmpty() && !name.contains('/') && !name.contains('\\'))
                list.add(Entry(Docs.buildDocumentUriUsingTree(uri, c.getString(0)), name, c.getString(2) == Docs.Document.MIME_TYPE_DIR))
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
        require(name == "settings.json" || name.matches(Regex("[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\\.json")))
        return safe(File(state, name))
    }
    private fun syncDir(dir: File) {
        val fd = Os.open(safe(dir).path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW, 0)
        try { require(OsConstants.S_ISDIR(Os.fstat(fd).st_mode)); Os.fsync(fd) } finally { Os.close(fd) }
    }
    private fun writeFile(file: File, raw: String, exclusive: Boolean) {
        safe(file); safe(file.parentFile!!)
        if (exclusive) {
            // Androidのapp-dataではhardlinkが拒否される。O_EXCLで確保し、
            // fsync完了後だけ呼出元を進める。途中停止の不完全journalは保存を止める。
            val fd = Os.open(file.path, OsConstants.O_WRONLY or OsConstants.O_CREAT or
                OsConstants.O_EXCL or OsConstants.O_NOFOLLOW, 384)
            FileOutputStream(fd).use { it.write(raw.toByteArray(Charsets.UTF_8)); it.fd.sync() }
            syncDir(file.parentFile!!)
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
    private fun snapshot(handle: String): Map<String, Any> {
        val files = linkedMapOf<String, String>(); val warnings = arrayListOf<String>()
        var count = 0; var total = 0L; var recognized = false
        fun add(path: String, read: () -> String) {
            try {
                val raw = read(); total += raw.toByteArray(Charsets.UTF_8).size
                require(total <= 64L * 1_048_576)
                files[path] = raw
            } catch (_: Exception) { warnings.add("読取できないファイル: $path") }
            require(total <= 64L * 1_048_576)
        }
        fun local(dir: File, prefix: String, depth: Int) {
            if (depth > 12) { warnings.add("深さの上限に達しました。"); return }
            for (file in safe(dir).listFiles() ?: error("読取不可")) {
                require(++count <= 5000)
                if (file.name.startsWith('.') || file.extension == "tmp") continue
                val path = "$prefix/${file.name}"
                if (file.canonicalPath != file.absolutePath) { warnings.add("symlinkを除外: $path"); continue }
                if (file.isDirectory) local(file, path, depth + 1)
                else if (file.extension in listOf("md", "json")) add(path) { text(safe(file).inputStream()) }
            }
        }
        fun visit(dir: Uri, prefix: String, depth: Int) {
            if (depth > 12) { warnings.add("深さの上限に達しました。"); return }
            for (e in children(dir, 5000 - count)) {
                require(++count <= 5000)
                if (e.name.startsWith('.') || e.name.endsWith(".tmp")) continue
                val path = "$prefix/${e.name}"
                if (e.dir) visit(e.uri, path, depth + 1)
                else if (e.name.substringAfterLast('.') in listOf("md", "json")) add(path) {
                    text(resolver.openInputStream(e.uri) ?: error("読取不可"))
                }
            }
        }
        if (handle == "sample") {
            for (name in folders) {
                val dir = File(sample, name)
                if (!dir.exists()) continue
                try { require(dir.isDirectory); recognized = true; local(dir, name, 1) }
                catch (_: Exception) { warnings.add("フォルダーの読取を中断: $name"); if (count > 5000 || total > 64L * 1_048_576) break }
            }
            val policy = File(sample, "POLICY.md")
            if (policy.exists()) {
                if (++count > 5000) warnings.add("件数上限によりPOLICY.mdを読取できません")
                else add("POLICY.md") { text(safe(policy).inputStream()) }
            }
        } else {
            for (e in children(tree(handle))) {
                if (e.name == "POLICY.md") {
                    if (++count > 5000) warnings.add("件数上限によりPOLICY.mdを読取できません")
                    else if (e.dir) warnings.add("POLICY.mdが通常ファイルではありません")
                    else add("POLICY.md") { text(resolver.openInputStream(e.uri) ?: error("読取不可")) }
                    continue
                }
                if (e.name !in folders) continue
                try { require(e.dir); recognized = true; visit(e.uri, e.name, 1) }
                catch (_: Exception) { warnings.add("フォルダーの読取を中断: ${e.name}"); if (count > 5000 || total > 64L * 1_048_576) break }
            }
        }
        return mapOf("files" to files, "warnings" to warnings, "recognized" to recognized)
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
                        if (path != "POLICY.md" && (parts.size < 2 || parts.size > 13 || parts[0] !in folders)) return@forEach
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
            "listJournals" -> return (state.list() ?: error("読取不可")).filter { it != "settings.json" && !it.startsWith('.') }
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
        if (method == "readSnapshot") return snapshot(handle)
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
