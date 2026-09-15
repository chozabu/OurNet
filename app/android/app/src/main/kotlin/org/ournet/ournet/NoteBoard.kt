package org.ournet.ournet

import android.app.Activity
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.View
import android.widget.*
import org.json.JSONArray
import org.json.JSONObject

/** Keep-style home-screen board: recent and pinned notes with quick capture.
 * Rows open the note; checking items stays in the single-note widget. The
 * board reads the same encrypted snapshot store and never decrypts history. */
object NoteBoard {
    const val MAX_NOTES = 40

    fun visible(state: JSONObject, widget: Int): Boolean {
        val config = WidgetStore.config(state, widget)
        return config?.optBoolean("show", true) ?: true
    }

    fun notes(state: JSONObject, widget: Int): List<JSONObject> =
        if (!visible(state, widget)) emptyList()
        else WidgetStore.objects(state.optJSONArray("board") ?: JSONArray()).take(MAX_NOTES)

    fun render(context: Context, id: Int) {
        val state = WidgetStore.read(context)
        val views = RemoteViews(context.packageName, R.layout.note_board_widget)
        views.setOnClickPendingIntent(R.id.widget_board_new_text, WidgetStore.launch(context, id, null))
        views.setOnClickPendingIntent(R.id.widget_board_new_list, WidgetStore.launch(context, id, null, true))
        views.setOnClickPendingIntent(R.id.widget_board_new_voice, WidgetStore.launch(context, id, null, voice = true))
        views.setOnClickPendingIntent(R.id.widget_board_title, PendingIntent.getActivity(context, 20000 + id,
            Intent(context, MainActivity::class.java).setAction(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        views.setOnClickPendingIntent(R.id.widget_board_settings, PendingIntent.getActivity(context, 30000 + id,
            Intent(context, NoteBoardConfiguration::class.java).putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        val adapter = Intent(context, NoteBoardService::class.java)
            .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
            .setData(Uri.parse("ournet-board://widget/$id"))
        @Suppress("DEPRECATION")
        views.setRemoteAdapter(R.id.widget_board_list, adapter)
        views.setEmptyView(R.id.widget_board_list, R.id.widget_board_empty)
        views.setTextViewText(R.id.widget_board_empty, when {
            !visible(state, id) -> "Contents hidden · tap ＋ to add a note"
            state.optString("profile").isEmpty() -> "Open OurNet to show your notes"
            else -> "No notes yet · tap ＋ to add one"
        })
        // Rows fill in the note to open. Fill-in intents require a mutable template.
        val template = Intent(context, MainActivity::class.java).setAction("org.ournet.WIDGET_OPEN")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val mutable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        views.setPendingIntentTemplate(R.id.widget_board_list,
            PendingIntent.getActivity(context, 10000 + id, template, PendingIntent.FLAG_UPDATE_CURRENT or mutable))
        AppWidgetManager.getInstance(context).updateAppWidget(id, views)
    }
}

class NoteBoardWidgetProvider : NoteWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) { async { WidgetStore.updateAll(context); WidgetStore.notifyFlutter() } }
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) { async { NoteBoard.render(context, id) } }
}

class NoteBoardService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
        NoteBoardFactory(applicationContext, intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, -1))
}

class NoteBoardFactory(private val context: Context, private val widget: Int) : RemoteViewsService.RemoteViewsFactory {
    private var rows: List<JSONObject> = emptyList()
    override fun onCreate() {}
    override fun onDataSetChanged() {
        rows = try { NoteBoard.notes(WidgetStore.read(context), widget) } catch (_: Exception) { emptyList() }
    }
    override fun onDestroy() { rows = emptyList() }
    override fun getCount() = rows.size
    override fun getViewTypeCount() = 1
    override fun hasStableIds() = true
    override fun getItemId(position: Int) = rows.getOrNull(position)?.optString("id")?.hashCode()?.toLong() ?: position.toLong()
    override fun getLoadingView(): RemoteViews? = null
    override fun getViewAt(position: Int): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.note_board_item)
        val note = rows.getOrNull(position) ?: return views
        views.setInt(R.id.board_item_background, "setColorFilter", note.optInt("color", Color.WHITE))
        fun text(view: Int, value: String) {
            views.setTextViewText(view, value)
            views.setViewVisibility(view, if (value.isBlank()) View.GONE else View.VISIBLE)
        }
        text(R.id.board_item_title, note.optString("title"))
        text(R.id.board_item_text, note.optString("text"))
        val checks = WidgetStore.objects(note.optJSONArray("checks") ?: JSONArray()).map { "☐  ${it.optString("text")}" }
        val more = note.optInt("moreUnchecked")
        val checked = note.optInt("checkedCount")
        text(R.id.board_item_checks, (checks + listOfNotNull(if (more > 0) "+ $more more" else null)).joinToString("\n"))
        text(R.id.board_item_meta, listOfNotNull(
            if (note.optBoolean("pinned")) "Pinned" else null,
            note.optString("voice").ifBlank { null }?.let { "🎤 $it" },
            if (note.optInt("pictures") > 0) "🖼 ${note.optInt("pictures")}" else null,
            if (note.optBoolean("reminder")) "⏰" else null,
            if (checked > 0) "$checked checked" else null,
            if (note.optBoolean("shared")) "Shared" else null,
        ).joinToString(" · "))
        if (note.optString("title").isBlank() && note.optString("text").isBlank() && checks.isEmpty()) {
            text(R.id.board_item_text, if (note.optString("voice").isNotBlank()) "Voice note" else if (note.optInt("pictures") > 0) "Photo" else "Empty note")
        }
        views.setOnClickFillInIntent(R.id.board_item_root, Intent()
            .setData(Uri.parse("ournet-widget://open/$widget/${Uri.encode(note.optString("id"))}"))
            .putExtra("widget", widget).putExtra("note", note.optString("id")).putExtra("checklist", false))
        return views
    }
}

class NoteBoardConfiguration : Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        setResult(RESULT_CANCELED)
        val id = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        if (id == AppWidgetManager.INVALID_APPWIDGET_ID) { finish(); return }
        WidgetStore.worker.execute {
            val stored = try { WidgetStore.read(this) } catch (_: Exception) { null }
            runOnUiThread {
                if (stored == null) {
                    Toast.makeText(this, "Unable to read widget settings", Toast.LENGTH_LONG).show(); finish(); return@runOnUiThread
                }
                val layout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(32, 32, 32, 32); setBackgroundColor(Color.rgb(237, 245, 240)) }
                setContentView(ScrollView(this).apply { addView(layout) })
                layout.addView(TextView(this).apply { text = "OurNet · Notes"; textSize = 24f; setTextColor(Color.BLACK) })
                layout.addView(TextView(this).apply {
                    text = "Shows your pinned and recent notes, with buttons for a new note or list. Anyone who can see this home screen can read what it shows."
                    setTextColor(Color.BLACK)
                })
                val show = CheckBox(this).apply {
                    text = "Show note contents on the home screen"; setTextColor(Color.BLACK)
                    isChecked = NoteBoard.visible(stored, id)
                }
                layout.addView(show)
                layout.addView(Button(this).apply { text = "Save widget"; setOnClickListener {
                    isEnabled = false
                    val visible = show.isChecked
                    WidgetStore.worker.execute {
                        try {
                            val latest = WidgetStore.read(this@NoteBoardConfiguration)
                            val configs = WidgetStore.objects(latest.getJSONArray("configs")).filter { it.optInt("widget") != id }
                            require(configs.size < WidgetStore.MAX_WIDGETS) { "Up to 16 note widgets are supported" }
                            latest.put("configs", JSONArray(configs + JSONObject().put("widget", id).put("kind", "board")
                                .put("profile", latest.optString("profile")).put("show", visible)))
                            WidgetStore.save(this@NoteBoardConfiguration, latest)
                            WidgetStore.updateAll(this@NoteBoardConfiguration); WidgetStore.notifyFlutter()
                            runOnUiThread {
                                setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)); finish()
                            }
                        } catch (error: Exception) {
                            runOnUiThread { Toast.makeText(this@NoteBoardConfiguration, error.message, Toast.LENGTH_LONG).show(); isEnabled = true }
                        }
                    }
                } })
            }
        }
    }
}
