package org.ournet.ournet

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private var channel: MethodChannel? = null
    private val queueDir get() = File(filesDir, "share-inbox").apply { mkdirs() }

    // Android may recreate the activity for configuration changes we do not
    // declare (e.g. resource/overlay updates right after install). A new engine
    // would run main() a second time while the first is still opening the
    // identity, and concurrent flutter_secure_storage workers delete each
    // other's keystore keys. Hand the running engine to the new activity.
    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        FlutterEngineCache.getInstance().get(RELAUNCH_ENGINE)?.also {
            FlutterEngineCache.getInstance().remove(RELAUNCH_ENGINE)
        }

    override fun shouldDestroyEngineWithHost() = !isChangingConfigurations

    override fun onDestroy() {
        if (isChangingConfigurations) flutterEngine?.let {
            FlutterEngineCache.getInstance().put(RELAUNCH_ENGINE, it)
        }
        super.onDestroy()
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        WidgetStore.attach(applicationContext, MethodChannel(engine.dartExecutor.binaryMessenger, "ournet/widgets"))
        WidgetStore.receiveLaunch(applicationContext, intent)
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "ournet/share")
        channel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "pending" -> worker.execute {
                    val pending = queueDir.listFiles()?.filter { it.extension == "json" }?.map {
                        val json = JSONObject(it.readText())
                        mapOf("id" to json.getString("id"), "text" to json.optString("text"),
                            "files" to (0 until json.getJSONArray("files").length()).map { i ->
                                val file = json.getJSONArray("files").getJSONObject(i)
                                mapOf("path" to file.getString("path"), "name" to file.getString("name"))
                            }, "error" to json.optString("error"))
                    } ?: emptyList()
                    runOnUiThread { result.success(pending) }
                }
                "ack" -> {
                    val id = call.argument<String>("id") ?: ""
                    if (!Regex("^[a-f0-9-]{36}$").matches(id)) { result.error("id", "Invalid share ID", null) }
                    else worker.execute {
                        File(queueDir, "$id.json").delete()
                        File(queueDir, id).deleteRecursively()
                        runOnUiThread { result.success(null) }
                    }
                }
                else -> result.notImplemented()
            }
        }
        receive(intent)
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        WidgetStore.receiveLaunch(applicationContext, intent)
        receive(intent)
    }
    @Suppress("DEPRECATION")
    private fun receive(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND && intent?.action != Intent.ACTION_SEND_MULTIPLE) return
        val share = Intent(intent)
        intent?.action = Intent.ACTION_MAIN
        worker.execute {
            val id = UUID.randomUUID().toString()
            val folder = File(queueDir, id).apply { mkdirs() }
            val json = JSONObject().put("id", id).put("text", share.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() ?: "")
            val files = JSONArray()
            try {
                val uris = if (share.action == Intent.ACTION_SEND_MULTIPLE)
                    share.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: arrayListOf()
                else listOfNotNull(share.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
                require(uris.size <= 32) { "Share up to 32 files at a time" }
                for ((i, uri) in uris.withIndex()) {
                    require(uri.scheme == "content") { "Only content-provider files can be shared" }
                    var name = "Shared file"
                    contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                        if (it.moveToFirst()) name = it.getString(0) ?: name
                    }
                    name = name.replace(Regex("[/\\\\\\x00-\\x1f]"), "_").take(255)
                    val target = File(folder, "$i.bin")
                    contentResolver.openInputStream(uri).use { input ->
                        requireNotNull(input) { "Cannot read shared file" }
                        target.outputStream().use { output ->
                            val buffer = ByteArray(131072)
                            var total = 0L
                            while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                total += count
                                require(total <= 64L * 1024 * 1024) { "File exceeds 64 MiB" }
                                output.write(buffer, 0, count)
                            }
                        }
                    }
                    files.put(JSONObject().put("path", target.absolutePath).put("name", name))
                }
            } catch (e: Exception) { json.put("error", e.message ?: "Unable to import share") }
            json.put("files", files)
            val temp = File(queueDir, "$id.tmp")
            temp.writeText(json.toString())
            temp.renameTo(File(queueDir, "$id.json"))
            runOnUiThread { channel?.invokeMethod("changed", null) }
        }
    }

    private companion object {
        const val RELAUNCH_ENGINE = "ournet-relaunch"
    }
}
