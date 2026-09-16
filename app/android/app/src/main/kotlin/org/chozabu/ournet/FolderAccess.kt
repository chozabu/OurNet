package org.chozabu.ournet

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract as Docs
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

/** SAF tree access. Provider I/O stays off Android's UI thread. No raw-storage permission. */
class FolderAccess(private val activity: Activity, channel: MethodChannel) {
    private val resolver get() = activity.contentResolver
    private val worker = Executors.newSingleThreadExecutor()
    private var picker: MethodChannel.Result? = null
    private val request = 4831
    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "pick") {
                if (picker != null) result.error("busy", "Folder picker already open", null)
                else {
                    picker = result
                    try {
                        activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                        }, request)
                    } catch (e: Exception) { picker = null; result.error("folder", e.message, null) }
                }
                return@setMethodCallHandler
            }
            worker.execute {
                try {
                    val tree = Uri.parse(requireNotNull(call.argument<String>("tree")))
                    require(tree.scheme == "content") { "Invalid document tree" }
                    val root = Docs.buildDocumentUriUsingTree(tree, Docs.getTreeDocumentId(tree))
                    require(info(root).directory) { "Folder unavailable" }
                    val path = call.argument<String>("path") ?: ""
                    val expected = call.argument<String>("expected")
                    val value: Any? = when (call.method) {
                        "scan" -> {
                            val found = linkedMapOf<String, Any>()
                            fun visit(parent: Uri, prefix: String, depth: Int) {
                                require(depth <= 64) { "Folder nesting exceeds 64 levels" }
                                for (doc in children(tree, parent)) {
                                    if (doc.name.startsWith(".ournet-", true)) continue
                                    safe(doc.name)
                                    val relative = if (prefix.isEmpty()) doc.name else "$prefix/${doc.name}"
                                    require(!found.containsKey(relative)) { "Duplicate provider filename: $relative" }
                                    found[relative] = doc.map()
                                    require(found.size <= 10000) { "Folder limit is 10,000 entries" }
                                    if (doc.directory) visit(doc.uri, relative, depth + 1)
                                }
                            }
                            visit(root, "", 0); found
                        }
                        "stat" -> resolve(tree, root, path)?.map()
                        "read" -> {
                            val doc = check(tree, root, path, expected) ?: error("File missing")
                            require(!doc.directory && doc.size <= LIMIT) { "File exceeds 64 MiB" }
                            val destination = File(requireNotNull(call.argument<String>("destination")))
                            resolver.openInputStream(doc.uri).use { input ->
                                requireNotNull(input) { "Cannot open file" }
                                destination.outputStream().use { output ->
                                    val buffer = ByteArray(131072); var total = 0L
                                    while (true) {
                                        val n = input.read(buffer); if (n < 0) break
                                        total += n; require(total <= LIMIT) { "File exceeds 64 MiB" }
                                        output.write(buffer, 0, n)
                                    }
                                }
                            }
                            check(tree, root, path, expected); null
                        }
                        "mkdir" -> {
                            val existing = resolve(tree, root, path)
                            if (existing != null) require(existing.directory) { "File blocks folder: $path" }
                            else {
                                val (parent, name) = parent(tree, root, path)
                                requireNotNull(Docs.createDocument(resolver, parent, Docs.Document.MIME_TYPE_DIR, name))
                            }; null
                        }
                        "put" -> {
                            val (parent, name) = parent(tree, root, path)
                            val tempName = ".ournet-${UUID.randomUUID()}.part"
                            var temp: Uri? = requireNotNull(Docs.createDocument(resolver, parent, "application/octet-stream", tempName))
                            var backup: Uri? = null
                            var written: Map<String, Any>? = null
                            try {
                                val source = File(requireNotNull(call.argument<String>("source")))
                                require(source.length() <= LIMIT) { "File exceeds 64 MiB" }
                                resolver.openOutputStream(temp!!, "w").use { output ->
                                    requireNotNull(output); source.inputStream().use { it.copyTo(output, 131072) }
                                }
                                val old = check(tree, root, path, expected)
                                require(old?.directory != true) { "Folder blocks file: $path" }
                                if (old != null) backup = requireNotNull(Docs.renameDocument(resolver, old.uri,
                                    ".ournet-${UUID.randomUUID()}.backup")) { "Provider cannot safely replace files" }
                                val committed = requireNotNull(Docs.renameDocument(resolver, temp!!, name)) {
                                    "Provider cannot safely rename files"
                                }
                                temp = null
                                val committedInfo = info(committed)
                                written = committedInfo.map()
                                require(committedInfo.name == name) { "Provider changed the filename; backup retained" }
                                backup?.let { Docs.deleteDocument(resolver, it) }; backup = null
                            } catch (e: Exception) {
                                // Never delete the old contents to force replacement. A failed
                                // rollback leaves a .ournet-*.backup document for recovery.
                                if (backup != null && resolve(tree, root, path) == null) {
                                    try { Docs.renameDocument(resolver, backup!!, name) } catch (_: Exception) {}
                                }
                                throw e
                            } finally { temp?.let { try { Docs.deleteDocument(resolver, it) } catch (_: Exception) {} } }
                            requireNotNull(written)
                        }
                        "move" -> {
                            val doc = check(tree, root, path, expected) ?: error("Source missing")
                            val destination = requireNotNull(call.argument<String>("destination"))
                            val existing = resolve(tree, root, destination)
                            require(existing == null || existing.uri == doc.uri) { "Rename destination already exists" }
                            val (oldParent, oldName) = parent(tree, root, path)
                            val (newParent, newName) = parent(tree, root, destination)
                            var moved = doc.uri
                            var transferred = false
                            try {
                                if (oldParent != newParent) {
                                    moved = requireNotNull(Docs.moveDocument(resolver, moved, oldParent, newParent)) {
                                        "Provider does not support moving this document"
                                    }
                                    transferred = true
                                }
                                if (oldName != newName) {
                                    moved = requireNotNull(Docs.renameDocument(resolver, moved, newName)) {
                                        "Provider does not support renaming this document"
                                    }
                                }
                                require(info(moved).name == newName) { "Provider changed the filename" }
                            } catch (e: Exception) {
                                try {
                                    if (info(moved).name != oldName) moved = requireNotNull(Docs.renameDocument(resolver, moved, oldName))
                                    if (transferred) Docs.moveDocument(resolver, moved, newParent, oldParent)
                                } catch (_: Exception) { /* Preserve the document at its last successful location. */ }
                                throw e
                            }
                            null
                        }
                        "remove" -> {
                            val doc = check(tree, root, path, expected)
                            if (doc != null) {
                                if (doc.directory) require(children(tree, doc.uri).isEmpty()) { "Folder still contains files: $path" }
                                require(Docs.deleteDocument(resolver, doc.uri)) { "Provider refused deletion" }
                            }; null
                        }
                        else -> error("Unknown folder operation")
                    }
                    activity.runOnUiThread { result.success(value) }
                } catch (e: Exception) { activity.runOnUiThread { result.error("folder", e.message ?: "Folder unavailable", null) } }
            }
        }
    }
    fun close() {
        picker?.error("closed", "Folder picker activity closed; retry", null)
        picker = null
        worker.shutdown()
    }
    fun activityResult(code: Int, result: Int, data: Intent?): Boolean {
        if (code != request) return false
        val pending = picker; picker = null
        if (result != Activity.RESULT_OK || data?.data == null) { pending?.success(null); return true }
        try {
            val uri = data.data!!
            val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            require(flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION != 0) { "Writable folder access required" }
            resolver.takePersistableUriPermission(uri, flags)
            pending?.success(uri.toString())
        } catch (e: Exception) { pending?.error("folder", e.message, null) }
        return true
    }
    private data class Doc(val uri: Uri, val name: String, val directory: Boolean, val size: Long, val modified: Long) {
        val token get() = if (directory) "directory" else "$modified/$size"
        fun map(): Map<String, Any> {
            require(directory || modified > 0) { "Provider does not expose reliable modification times: $name" }
            return mapOf("directory" to directory, "size" to size, "token" to token)
        }
    }
    private val projection = arrayOf(Docs.Document.COLUMN_DOCUMENT_ID, Docs.Document.COLUMN_DISPLAY_NAME,
        Docs.Document.COLUMN_MIME_TYPE, Docs.Document.COLUMN_SIZE, Docs.Document.COLUMN_LAST_MODIFIED)
    private fun info(uri: Uri): Doc = resolver.query(uri, projection, null, null, null).use { cursor ->
        requireNotNull(cursor) { "Folder permission unavailable" }
        require(cursor.moveToFirst()) { "Folder or file unavailable" }
        Doc(uri, cursor.getString(1), cursor.getString(2) == Docs.Document.MIME_TYPE_DIR, cursor.getLong(3), cursor.getLong(4))
    }
    private fun children(tree: Uri, parent: Uri): List<Doc> {
        val uri = Docs.buildChildDocumentsUriUsingTree(tree, Docs.getDocumentId(parent))
        return resolver.query(uri, projection, null, null, null).use { cursor ->
            requireNotNull(cursor) { "Cannot list folder; permission may have been revoked" }
            val result = mutableListOf<Doc>()
            while (cursor.moveToNext()) {
                require(result.size < 10000) { "Folder has too many entries" }
                result.add(Doc(Docs.buildDocumentUriUsingTree(tree, cursor.getString(0)), cursor.getString(1),
                    cursor.getString(2) == Docs.Document.MIME_TYPE_DIR, cursor.getLong(3), cursor.getLong(4)))
            }
            require(!cursor.extras.getBoolean(Docs.EXTRA_LOADING, false)) { "Provider is still loading; retry later" }
            result
        }
    }
    private fun safe(name: String) {
        require(name.isNotEmpty() && name != "." && name != ".." && !name.contains('/') && !name.contains('\\') &&
            !name.startsWith(".ournet-", true)) { "Unsupported filename" }
    }
    private fun resolve(tree: Uri, root: Uri, path: String): Doc? {
        var doc = info(root)
        for (part in path.split('/')) {
            safe(part)
            require(doc.directory) { "Parent is not a folder" }
            val matches = children(tree, doc.uri).filter { it.name == part }
            require(matches.size <= 1) { "Duplicate filename: $part" }
            doc = matches.singleOrNull() ?: return null
        }
        return doc
    }
    private fun parent(tree: Uri, root: Uri, path: String): Pair<Uri, String> {
        val name = path.substringAfterLast('/'); safe(name)
        val parent = if ('/' in path) resolve(tree, root, path.substringBeforeLast('/')) else info(root)
        require(parent?.directory == true) { "Parent folder missing" }
        return parent!!.uri to name
    }
    private fun check(tree: Uri, root: Uri, path: String, expected: String?): Doc? {
        val doc = resolve(tree, root, path)
        require(doc?.token == expected) { "File changed during sync: $path; local edit preserved" }
        return doc
    }
    companion object { private const val LIMIT = 64L * 1024 * 1024 }
}
