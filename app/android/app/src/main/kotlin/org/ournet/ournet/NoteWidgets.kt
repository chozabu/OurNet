package org.ournet.ournet

import android.app.Activity
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.view.View
import android.widget.*
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** A small local rendering snapshot and durable desired-state outbox. No
 * signing keys, networking or shared-note protocol lives in the Android host. */
object WidgetStore {
    val worker = ThreadPoolExecutor(1, 1, 0L, TimeUnit.MILLISECONDS,
        ArrayBlockingQueue<Runnable>(64), ThreadPoolExecutor.AbortPolicy())
    private val main = Handler(Looper.getMainLooper())
    var changed: (() -> Unit)? = null
    private var cached: JSONObject? = null
    const val MAX_PENDING = 128
    const val MAX_WIDGETS = 16
    private const val MAX_BYTES = 512 * 1024

    fun notifyFlutter() { main.post { changed?.invoke() } }
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        return (store.getKey("ournet-widget-v1", null) as? SecretKey) ?: KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("ournet-widget-v1", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    private fun file(context: Context) = AtomicFile(File(context.noBackupFilesDir, "note-widgets.bin"))
    @Synchronized fun read(context: Context): JSONObject {
        cached?.let { return JSONObject(it.toString()) }
        val atomic = file(context)
        val state = if (!atomic.baseFile.exists()) JSONObject() else {
            require(atomic.baseFile.length() <= MAX_BYTES + 64) { "Widget storage exceeds its limit" }
            val bytes = atomic.openRead().use { it.readBytes() }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
            JSONObject(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8))
        }
        if (!state.has("configs")) state.put("configs", JSONArray())
        if (!state.has("pending")) state.put("pending", JSONArray())
        if (!state.has("catalog")) state.put("catalog", JSONArray())
        if (!state.has("snapshots")) state.put("snapshots", JSONArray())
        if (!state.has("board")) state.put("board", JSONArray())
        cached = JSONObject(state.toString())
        return state
    }
    @Synchronized fun save(context: Context, state: JSONObject) {
        val plain = state.toString().toByteArray(Charsets.UTF_8)
        require(plain.size <= MAX_BYTES) { "Widget storage is full. Open OurNet to sync." }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val atomic = file(context)
        val stream = atomic.startWrite()
        try {
            stream.write(cipher.iv); stream.write(cipher.doFinal(plain)); atomic.finishWrite(stream)
            cached = JSONObject(state.toString())
        } catch (error: Exception) { atomic.failWrite(stream); cached = null; throw error }
    }
    fun objects(array: JSONArray): List<JSONObject> = (0 until array.length()).map { array.getJSONObject(it) }
    fun config(state: JSONObject, widget: Int) = objects(state.getJSONArray("configs")).find { it.optInt("widget") == widget }
    fun snapshot(state: JSONObject, widget: Int) = objects(state.getJSONArray("snapshots")).find { it.optInt("widget") == widget }
    fun updateAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        for (id in manager.getAppWidgetIds(ComponentName(context, NoteWidgetProvider::class.java))) render(context, id)
        for (id in manager.getAppWidgetIds(ComponentName(context, CaptureWidgetProvider::class.java))) renderCapture(context, id)
        val boards = manager.getAppWidgetIds(ComponentName(context, NoteBoardWidgetProvider::class.java))
        for (id in boards) NoteBoard.render(context, id)
        @Suppress("DEPRECATION")
        if (boards.isNotEmpty()) manager.notifyAppWidgetViewDataChanged(boards, R.id.widget_board_list)
    }
    /** Board widgets currently placed; Dart prepares the board only when one exists. */
    fun boardIds(context: Context): IntArray =
        AppWidgetManager.getInstance(context).getAppWidgetIds(ComponentName(context, NoteBoardWidgetProvider::class.java))
    fun launch(context: Context, widget: Int, note: String?, checklist: Boolean = false): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = "org.ournet.WIDGET_OPEN"
            data = Uri.parse("ournet-widget://open/$widget/${Uri.encode(note ?: if (checklist) "checklist" else "text")}")
            putExtra("widget", widget); putExtra("note", note); putExtra("checklist", checklist)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        return PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
    private fun settings(context: Context, widget: Int) = PendingIntent.getActivity(context, widget,
        Intent(context, NoteWidgetConfiguration::class.java).putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widget),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    fun render(context: Context, id: Int) {
        val state = read(context)
        val config = config(state, id)
        val snapshot = snapshot(state, id)
        val available = config != null && config.optString("profile") == state.optString("profile") &&
            snapshot?.optBoolean("available") == true
        val show = available && config!!.optBoolean("show")
        val views = RemoteViews(context.packageName, R.layout.note_widget)
        val open = launch(context, id, config?.optString("note"))
        views.setOnClickPendingIntent(R.id.widget_title, open)
        views.setOnClickPendingIntent(R.id.widget_text, open)
        views.setOnClickPendingIntent(R.id.widget_open, open)
        views.setOnClickPendingIntent(R.id.widget_settings, settings(context, id))
        views.setTextViewText(R.id.widget_title, if (show) snapshot!!.optString("title", "Note") else "OurNet note")
        views.setTextViewText(R.id.widget_text, when {
            config == null -> "Choose a note in widget settings"
            !available -> "Note unavailable · open OurNet or choose another note"
            !show -> "Contents hidden · tap to edit"
            else -> snapshot!!.optString("text")
        })
        views.removeAllViews(R.id.widget_checks)
        val pending = objects(state.getJSONArray("pending")).filter {
            it.optString("note") == config?.optString("note") && it.optString("profile") == config?.optString("profile")
        }
        val status = when {
            pending.any { it.has("error") } -> "Saved change needs review · Settings"
            pending.isNotEmpty() -> "Saved here · Open OurNet to sync"
            available -> if (snapshot!!.optBoolean("shared")) "Shared · Updates when OurNet runs" else "Available offline"
            else -> "Open OurNet to refresh"
        }
        views.setTextViewText(R.id.widget_status, status)
        if (show) {
            val height = AppWidgetManager.getInstance(context).getAppWidgetOptions(id).getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 250)
            val count = ((height - 125) / 48).coerceIn(1, 12)
            val checks = objects(snapshot!!.optJSONArray("checks") ?: JSONArray())
            for (check in checks.take(count)) {
                val field = "check:${check.getString("id")}:done"
                val last = pending.lastOrNull { it.optString("field") == field && !it.has("error") }
                val done = last?.optBoolean("value") ?: check.optBoolean("done")
                val token = last?.optString("id") ?: check.optString("token")
                val row = RemoteViews(context.packageName, R.layout.note_widget_row)
                row.setTextViewText(R.id.widget_check, if (done) "☑" else "☐")
                row.setContentDescription(R.id.widget_check, "${if (done) "Uncheck" else "Check"} ${check.optString("text")}")
                row.setTextViewText(R.id.widget_item_text, check.optString("text"))
                row.setOnClickPendingIntent(R.id.widget_item_text, open)
                val intent = Intent(context, NoteWidgetProvider::class.java).apply {
                    action = "org.ournet.WIDGET_CHECK"
                    data = Uri.parse("ournet-widget://check/$id/${Uri.encode(field)}/${Uri.encode(token)}")
                    putExtra("widget", id); putExtra("field", field); putExtra("token", token)
                    addFlags(Intent.FLAG_RECEIVER_FOREGROUND)
                }
                row.setOnClickPendingIntent(R.id.widget_check, PendingIntent.getBroadcast(context, 0, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
                views.addView(R.id.widget_checks, row)
            }
            views.setTextViewText(R.id.widget_open, if (checks.size > count || snapshot.optBoolean("more")) "Open full note ↗" else "Open in OurNet ↗")
        }
        AppWidgetManager.getInstance(context).updateAppWidget(id, views)
    }
    fun renderCapture(context: Context, id: Int) {
        val views = RemoteViews(context.packageName, R.layout.capture_widget)
        views.setOnClickPendingIntent(R.id.widget_new_text, launch(context, id, null))
        views.setOnClickPendingIntent(R.id.widget_new_checklist, launch(context, id, null, true))
        AppWidgetManager.getInstance(context).updateAppWidget(id, views)
    }
    fun toggle(context: Context, intent: Intent) {
        val state = read(context)
        val id = intent.getIntExtra("widget", -1)
        val config = config(state, id) ?: return
        val snapshot = snapshot(state, id) ?: return
        if (config.optString("profile") != state.optString("profile") || !config.optBoolean("show") || !snapshot.optBoolean("available")) return
        val field = intent.getStringExtra("field") ?: return
        val check = objects(snapshot.optJSONArray("checks") ?: JSONArray()).find { "check:${it.optString("id")}:done" == field } ?: return
        val pending = state.getJSONArray("pending")
        val previous = objects(pending).lastOrNull { it.optString("note") == config.optString("note") &&
            it.optString("profile") == config.optString("profile") && it.optString("field") == field && !it.has("error") }
        val token = previous?.optString("id") ?: check.optString("token")
        if (intent.getStringExtra("token") != token) return // stale/repeated delivery
        if (pending.length() >= MAX_PENDING) { render(context, id); return }
        val op = JSONObject().put("id", UUID.randomUUID().toString())
            .put("title", snapshot.optString("title")).put("label", check.optString("text"))
            .put("profile", config.getString("profile")).put("note", config.getString("note"))
            .put("epoch", snapshot.getString("epoch")).put("field", field)
            .put("value", !(previous?.optBoolean("value") ?: check.optBoolean("done")))
            .put("parents", check.getJSONArray("parents"))
        pending.put(op)
        save(context, state) // commit before reporting the optimistic checkmark
        updateAll(context)
        notifyFlutter()
    }

    /** All host operations run on the same bounded worker as receivers. */
    fun attach(context: Context, channel: MethodChannel) {
        changed = { channel.invokeMethod("changed", null) }
        channel.setMethodCallHandler { call, result ->
            try { worker.execute {
                try {
                    val state = read(context)
                    var response: Any? = null
                    when (call.method) {
                        "activate" -> {
                            val profile = call.argument<String>("profile")!!
                            if (state.optString("profile") != profile) {
                                state.put("profile", profile).put("snapshots", JSONArray()).put("catalog", JSONArray()).put("board", JSONArray())
                                save(context, state); updateAll(context)
                            }
                            val launch = state.optJSONObject("launch")
                            if (launch != null && launch.optString("profile").isEmpty()) { launch.put("profile", profile); save(context, state) }
                        }
                        "state" -> response = toValue(state.put("boards", JSONArray(boardIds(context).toList())))
                        "publish" -> {
                            if (call.argument<String>("profile") == state.optString("profile")) {
                                val catalog = JSONArray(call.argument<List<Any>>("catalog") ?: emptyList<Any>())
                                val snapshots = JSONArray(call.argument<List<Any>>("snapshots") ?: emptyList<Any>())
                                require(catalog.length() <= 200 && snapshots.length() <= MAX_WIDGETS)
                                for (snapshot in objects(snapshots)) {
                                    val old = WidgetStore.snapshot(state, snapshot.optInt("widget"))
                                    for (check in objects(snapshot.optJSONArray("checks") ?: JSONArray())) {
                                        val before = old?.optJSONArray("checks")?.let { a -> objects(a).find { it.optString("id") == check.optString("id") } }
                                        val token = if (before != null && old.optString("note") == snapshot.optString("note") && old.optString("epoch") == snapshot.optString("epoch") && before.optString("parents") == check.optString("parents") && before.optBoolean("done") == check.optBoolean("done")) before.optString("token") else UUID.randomUUID().toString()
                                        check.put("token", token)
                                    }
                                }
                                val board = JSONArray(call.argument<List<Any>>("board") ?: emptyList<Any>())
                                require(board.length() <= NoteBoard.MAX_NOTES)
                                state.put("catalog", catalog).put("snapshots", snapshots).put("board", board)
                                save(context, state); updateAll(context)
                            }
                        }
                        "ack" -> { state.put("pending", JSONArray(objects(state.getJSONArray("pending")).filter { it.optString("id") != call.argument<String>("id") })); save(context, state) }
                        "failed" -> {
                            objects(state.getJSONArray("pending")).find { it.optString("id") == call.argument<String>("id") }?.put("error", call.argument<String>("error"))
                            save(context, state)
                        }
                        "pinBoard" -> {
                            val manager = AppWidgetManager.getInstance(context)
                            response = android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O &&
                                manager.isRequestPinAppWidgetSupported &&
                                manager.requestPinAppWidget(ComponentName(context, NoteBoardWidgetProvider::class.java), null, null)
                        }
                        "claim" -> { if (state.optJSONObject("launch")?.optString("id") == call.argument<String>("id")) { state.remove("launch"); save(context, state) } }
                        else -> { main.post { result.notImplemented() }; return@execute }
                    }
                    main.post { result.success(response) }
                } catch (error: Exception) { cached = null; main.post { result.error("widget", error.message, null) } }
            } } catch (error: Exception) { result.error("busy", "Widget is busy; try again", null) }
        }
    }
    fun receiveLaunch(context: Context, intent: Intent?) {
        if (intent?.action != "org.ournet.WIDGET_OPEN") return
        val copy = Intent(intent); intent.action = Intent.ACTION_MAIN
        worker.execute {
            val state = read(context)
            val widget = copy.getIntExtra("widget", -1)
            val config = config(state, widget)
            // Bind existing-note links to their configured profile, never the
            // profile that happens to be open when a stale PendingIntent fires.
            state.put("launch", JSONObject().put("id", UUID.randomUUID().toString())
                .put("profile", config?.optString("profile") ?: state.optString("profile"))
                .put("note", copy.getStringExtra("note")).put("checklist", copy.getBooleanExtra("checklist", false)))
            save(context, state); notifyFlutter()
        }
    }
    private fun toValue(value: Any?): Any? = when (value) {
        is JSONObject -> value.keys().asSequence().associateWith { toValue(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { toValue(value.get(it)) }
        JSONObject.NULL -> null
        else -> value
    }
}

open class NoteWidgetProvider : AppWidgetProvider() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == "org.ournet.WIDGET_CHECK") {
            val result = goAsync()
            try { WidgetStore.worker.execute {
                try { WidgetStore.toggle(context, intent) } catch (_: Exception) { WidgetStore.notifyFlutter() }
                finally { result.finish() }
            } } catch (_: Exception) { result.finish() }
        } else super.onReceive(context, intent)
    }
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) { async { WidgetStore.updateAll(context) } }
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) { async { WidgetStore.render(context, id) } }
    override fun onDeleted(context: Context, ids: IntArray) { async {
        val state = WidgetStore.read(context)
        for (key in listOf("configs", "snapshots")) state.put(key, JSONArray(WidgetStore.objects(state.getJSONArray(key)).filter { !ids.contains(it.optInt("widget")) }))
        WidgetStore.save(context, state)
        // Accepted local edits outlive removal of the widget.
    } }
    protected fun async(work: () -> Unit) {
        val result = goAsync()
        try { WidgetStore.worker.execute { try { work() } catch (_: Exception) { } finally { result.finish() } } }
        catch (_: Exception) { result.finish() }
    }
}

class CaptureWidgetProvider : NoteWidgetProvider() {
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) { async { WidgetStore.renderCapture(context, id) } }
}

class NoteWidgetConfiguration : Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        setResult(RESULT_CANCELED)
        val id = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        if (id == AppWidgetManager.INVALID_APPWIDGET_ID) { finish(); return }
        WidgetStore.worker.execute {
            try {
                val stored = WidgetStore.read(this)
                val profile = stored.optString("profile")
                val old = WidgetStore.config(stored, id)
                val catalog = WidgetStore.objects(stored.getJSONArray("catalog"))
                val pending = WidgetStore.objects(stored.getJSONArray("pending")).filter { it.optString("profile") == profile }
                runOnUiThread {
                    val layout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(32, 32, 32, 32); setBackgroundColor(Color.rgb(237, 245, 240)) }
                    val scroll = ScrollView(this).apply { addView(layout) }; setContentView(scroll)
                    layout.addView(TextView(this).apply { text = "OurNet · Single note"; textSize = 24f; setTextColor(Color.BLACK) })
                    layout.addView(TextView(this).apply { text = "Choose a note or checklist. Home-screen contents can be seen by anyone using this device."; setTextColor(Color.BLACK) })
                    val picker = Spinner(this)
                    picker.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, catalog.map { it.optString("title", "Note") })
                    picker.setSelection(catalog.indexOfFirst { it.optString("id") == old?.optString("note") }.coerceAtLeast(0))
                    layout.addView(picker)
                    val show = CheckBox(this).apply { text = "Show contents on the home screen"; isChecked = old?.optBoolean("show") ?: false; setTextColor(Color.BLACK) }
                    layout.addView(show)
                    if (catalog.isEmpty()) layout.addView(TextView(this).apply { text = "Open OurNet and create or open a note first, then return here."; setTextColor(Color.BLACK) })
                    layout.addView(Button(this).apply { text = "Open OurNet"; setOnClickListener { startActivity(Intent(this@NoteWidgetConfiguration, MainActivity::class.java)) } })
                    for (op in pending.filter { it.has("error") }.take(20)) {
                        layout.addView(TextView(this).apply { text = "${op.optString("title")} · ${op.optString("label")}: ${if (op.optBoolean("value")) "checked" else "unchecked"}. ${op.optString("error")}"; setTextColor(Color.BLACK) })
                        layout.addView(Button(this).apply { text = "Retry saved change"; setOnClickListener {
                            WidgetStore.worker.execute {
                                val latest = WidgetStore.read(this@NoteWidgetConfiguration)
                                WidgetStore.objects(latest.getJSONArray("pending")).find { it.optString("id") == op.optString("id") }?.remove("error")
                                WidgetStore.save(this@NoteWidgetConfiguration, latest); WidgetStore.notifyFlutter()
                                runOnUiThread { startActivity(Intent(this@NoteWidgetConfiguration, MainActivity::class.java)); recreate() }
                            }
                        } })
                        layout.addView(Button(this).apply { text = "Discard this pending change"; setOnClickListener {
                            WidgetStore.worker.execute {
                                val latest = WidgetStore.read(this@NoteWidgetConfiguration)
                                latest.put("pending", JSONArray(WidgetStore.objects(latest.getJSONArray("pending")).filter { it.optString("id") != op.optString("id") }))
                                WidgetStore.save(this@NoteWidgetConfiguration, latest); WidgetStore.updateAll(this@NoteWidgetConfiguration)
                                runOnUiThread { recreate() }
                            }
                        } })
                    }
                    layout.addView(Button(this).apply { text = "Save widget"; isEnabled = catalog.isNotEmpty(); setOnClickListener {
                        isEnabled = false
                        val selected = catalog[picker.selectedItemPosition].getString("id")
                        val visible = show.isChecked
                        WidgetStore.worker.execute {
                            try {
                                val latest = WidgetStore.read(this@NoteWidgetConfiguration)
                                val configs = WidgetStore.objects(latest.getJSONArray("configs")).filter { it.optInt("widget") != id }
                                require(configs.size < WidgetStore.MAX_WIDGETS) { "Up to 16 note widgets are supported" }
                                require(profile == latest.optString("profile")) { "Profile changed; reopen widget settings" }
                                latest.put("configs", JSONArray(configs + JSONObject().put("widget", id).put("profile", profile).put("note", selected).put("show", visible)))
                                latest.put("snapshots", JSONArray(WidgetStore.objects(latest.getJSONArray("snapshots")).filter { it.optInt("widget") != id }))
                                WidgetStore.save(this@NoteWidgetConfiguration, latest); WidgetStore.render(this@NoteWidgetConfiguration, id); WidgetStore.notifyFlutter()
                                // Bring the existing engine forward to prepare the selected snapshot.
                                runOnUiThread {
                                    startActivity(Intent(this@NoteWidgetConfiguration, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP))
                                    setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)); finish()
                                }
                            } catch (error: Exception) { runOnUiThread { Toast.makeText(this@NoteWidgetConfiguration, error.message, Toast.LENGTH_LONG).show(); isEnabled = true } }
                        }
                    } })
                }
            } catch (error: Exception) { runOnUiThread { Toast.makeText(this, "Unable to read widget settings", Toast.LENGTH_LONG).show(); finish() } }
        }
    }
}
