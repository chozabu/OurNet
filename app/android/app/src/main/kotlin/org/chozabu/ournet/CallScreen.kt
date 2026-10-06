package org.chozabu.ournet

import android.app.Activity
import android.os.Build
import android.view.WindowManager
import java.lang.ref.WeakReference

/**
 * Shows OurNet over the lock screen only while a call rings or lasts, so a
 * call can be answered, and carries on, without unlocking the phone. Ringing
 * also turns the screen on (with the incoming-call notification's full-screen
 * intent). Outside calls the lock screen covers OurNet as usual.
 */
object CallScreen {
    private var show = false
    private var wake = false
    private var activity: WeakReference<Activity>? = null

    /** The activity on screen; it takes the current state at once. */
    fun attach(activity: Activity) {
        this.activity = WeakReference(activity)
        apply(activity)
    }

    fun detach(activity: Activity) {
        if (this.activity?.get() === activity) this.activity = null
    }

    fun set(show: Boolean, wake: Boolean) {
        this.show = show
        this.wake = wake
        activity?.get()?.let { it.runOnUiThread { apply(it) } }
    }

    private fun apply(activity: Activity) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            activity.setShowWhenLocked(show)
            activity.setTurnScreenOn(wake)
        } else {
            @Suppress("DEPRECATION")
            val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            @Suppress("DEPRECATION")
            if (show) activity.window.addFlags(flags) else activity.window.clearFlags(flags)
        }
    }
}
