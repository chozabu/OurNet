package org.ournet.ournet

import android.appwidget.AppWidgetHost
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.Callable
import java.util.concurrent.TimeUnit

/** Run only against the isolated .profile package. Uses the real Android
 * keystore, AtomicFile, RemoteViews provider and launcher binding service. */
class NoteWidgetTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private fun <T> onWorker(action: () -> T): T = WidgetStore.worker.submit(Callable { action() }).get(15, TimeUnit.SECONDS)
    private fun fixture(id: Int) = JSONObject().put("profile", "test-profile")
        .put("catalog", JSONArray().put(JSONObject().put("id", "test-note").put("title", "Shopping")))
        .put("pending", JSONArray())
        .put("configs", JSONArray().put(JSONObject().put("widget", id).put("profile", "test-profile").put("note", "test-note").put("show", true)))
        .put("snapshots", JSONArray().put(JSONObject().put("widget", id).put("profile", "test-profile").put("note", "test-note")
            .put("available", true).put("epoch", "epoch-1").put("title", "Shopping").put("text", "Private fixture text")
            .put("checks", JSONArray().put(JSONObject().put("id", "milk").put("text", "Milk").put("done", false).put("parents", JSONArray()).put("token", "render-1")))))
    private fun tap(id: Int, token: String) = Intent(context, NoteWidgetProvider::class.java)
        .setAction("org.ournet.WIDGET_CHECK").putExtra("widget", id).putExtra("field", "check:milk:done").putExtra("token", token)

    @Test fun nativeOutboxResizePrivacyAndDeepLinks() {
        assertEquals("org.ournet.ournet.profile", context.packageName)
        val host = AppWidgetHost(context, 9841)
        val id = host.allocateAppWidgetId()
        val manager = AppWidgetManager.getInstance(context)
        val original = onWorker { WidgetStore.read(context) }
        try {
            assertTrue("Grant test launcher binding with adb shell appwidget grantbind --package org.ournet.ournet.profile --user 0",
                manager.bindAppWidgetIdIfAllowed(id, ComponentName(context, NoteWidgetProvider::class.java)))
            onWorker {
                WidgetStore.save(context, fixture(id))
                WidgetStore.render(context, id)
                WidgetStore.toggle(context, tap(id, "render-1"))
                WidgetStore.toggle(context, tap(id, "render-1"))
                var state = WidgetStore.read(context)
                assertEquals(1, state.getJSONArray("pending").length())
                assertTrue(state.getJSONArray("pending").getJSONObject(0).getBoolean("value"))
                val token = state.getJSONArray("pending").getJSONObject(0).getString("id")
                WidgetStore.toggle(context, tap(id, token))
                state = WidgetStore.read(context)
                assertEquals(2, state.getJSONArray("pending").length())
                assertFalse(state.getJSONArray("pending").getJSONObject(1).getBoolean("value"))
                // Hidden contents disable even an old valid home-screen action.
                WidgetStore.config(state, id)!!.put("show", false)
                WidgetStore.save(context, state)
                WidgetStore.toggle(context, tap(id, state.getJSONArray("pending").getJSONObject(1).getString("id")))
                assertEquals(2, WidgetStore.read(context).getJSONArray("pending").length())
                WidgetStore.render(context, id)
                assertFalse(java.io.File(context.noBackupFilesDir, "note-widgets.bin").readText(Charsets.ISO_8859_1).contains("Private fixture text"))
            }
            instrumentation.runOnMainSync {
                val view = host.createView(context, id, manager.getAppWidgetInfo(id))
                view.updateAppWidgetSize(null, 180, 130, 360, 400)
            }
            val intent = Intent(context, MainActivity::class.java).setAction("org.ournet.WIDGET_OPEN")
                .putExtra("widget", id).putExtra("note", "test-note")
            WidgetStore.receiveLaunch(context, intent)
            onWorker {
                val launch = WidgetStore.read(context).getJSONObject("launch")
                assertEquals("test-note", launch.getString("note"))
                assertEquals("test-profile", launch.getString("profile"))
                assertEquals(Intent.ACTION_MAIN, intent.action)
            }
        } finally {
            onWorker { WidgetStore.save(context, original) }
            host.deleteAppWidgetId(id)
        }
    }

    @Test fun staleProfileAndQueueLimit() {
        assertEquals("org.ournet.ournet.profile", context.packageName)
        onWorker {
            val original = WidgetStore.read(context)
            try {
                val state = fixture(0).put("profile", "different-profile")
                WidgetStore.save(context, state)
                WidgetStore.toggle(context, tap(0, "render-1"))
                assertEquals(0, WidgetStore.read(context).getJSONArray("pending").length())
                state.put("profile", "test-profile")
                val full = JSONArray()
                repeat(WidgetStore.MAX_PENDING) { full.put(JSONObject().put("id", "old-$it")) }
                state.put("pending", full)
                WidgetStore.save(context, state)
                WidgetStore.toggle(context, tap(0, "render-1"))
                assertEquals(WidgetStore.MAX_PENDING, WidgetStore.read(context).getJSONArray("pending").length())
            } finally { WidgetStore.save(context, original) }
        }
    }

    // Run these two methods in separate instrumentation processes, stopping the
    // profile package between them. This checks actual disk/keystore cold start.
    @Test fun persistColdFixture() {
        assertEquals("org.ournet.ournet.profile", context.packageName)
        onWorker {
            val original = WidgetStore.read(context)
            val state = fixture(0).put("testOriginal", original).put("coldMarker", "saved-before-process-death")
            WidgetStore.save(context, state)
            WidgetStore.toggle(context, tap(0, "render-1"))
        }
    }
    @Test fun readColdFixture() {
        onWorker {
            val state = WidgetStore.read(context)
            try {
                assertEquals("saved-before-process-death", state.getString("coldMarker"))
                assertEquals(1, state.getJSONArray("pending").length())
                assertTrue(state.getJSONArray("pending").getJSONObject(0).getBoolean("value"))
                WidgetStore.toggle(context, tap(0, "render-1"))
                assertEquals(1, WidgetStore.read(context).getJSONArray("pending").length())
            } finally { WidgetStore.save(context, state.getJSONObject("testOriginal")) }
        }
    }
}
