package org.chozabu.ournet

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.Looper

/**
 * Ringing for a call announced by a push wake (PushWake), before the app has
 * the call itself. A friend's device that cannot reach this phone asks the
 * push server to wake it with the call's ID. This rings at once, with the
 * ringtone and a full-screen notification, and starts [ConnectionService]
 * so the app comes up and receives the offer the caller keeps sending. The
 * app's own incoming-call notification then replaces this one (it has the
 * same ID), and the app answers or declines as the person already did here
 * (`callAction` on `ournet/push`). A `cancel` wake, or [TIMEOUT], ends it.
 */
object IncomingCall {
    private const val CHANNEL = "incoming_calls_push"

    /** The app's incoming-call notification (`_callId` in notifications.dart), which replaces this one. */
    private const val NOTIFICATION = 1

    /** How long it rings, and then how long an answer or decline waits for the app. */
    private const val TIMEOUT = 60_000L
    private const val EXTRA_CALL = "org.chozabu.ournet.call"
    private const val EXTRA_ACTION = "org.chozabu.ournet.callAction"

    /** The call ringing from a push, until the app takes it over or it ends. */
    @Volatile var ringing: String? = null
        private set

    /** What the person did while it rang: the call and `answer` or `decline`. */
    private var action: Pair<String, String>? = null
    private var context: Context? = null
    private val main = Handler(Looper.getMainLooper())
    private val expire = Runnable { context?.let { end(it) } }

    /** Ringing, or an answer or decline the app has not taken yet: keeps [ConnectionService]. */
    val pending get() = ringing != null || action != null

    /** Keeps OurNet over the lock screen: ringing, or answered and waiting for the call. */
    val holdsScreen get() = ringing != null || action?.second == "answer"

    fun ring(context: Context, call: String) = main.post {
        // The app rings for it already, or is in another call (the offer will find it busy).
        if (ConnectionService.callBusy || ringing == call) return@post
        this.context = context
        ringing = call
        action = null
        CallScreen.set(show = true, wake = true)
        context.getSystemService(NotificationManager::class.java).notify(NOTIFICATION, notification(context, call))
        main.removeCallbacks(expire)
        main.postDelayed(expire, TIMEOUT)
        ConnectionService.startForCall(context)
    }

    /** The caller gave up, or another of the person's devices answered. */
    fun cancel(context: Context, call: String) = main.post {
        if (ringing == call || action?.first == call) end(context)
    }

    /** The app has the call and rings for it itself. */
    fun takeOver() {
        ringing = null
    }

    /** What the person did on [call] while it rang from a push, once. */
    fun takeAction(call: String?): String? {
        val taken = action?.takeIf { it.first == call }?.second
        if (taken != null) action = null
        return taken
    }

    /** The activity opened from the notification: Answer, or the notification itself. */
    fun opened(context: Context, intent: Intent?) {
        val call = intent?.getStringExtra(EXTRA_CALL) ?: return
        if (intent.getStringExtra(EXTRA_ACTION) == "answer") act(context, call, "answer")
    }

    private fun act(context: Context, call: String, what: String) = main.post {
        if (ringing != call) return@post
        ringing = null
        action = call to what
        context.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION)
        CallScreen.set(show = what == "answer" || ConnectionService.callBusy, wake = false)
        // Waits this long for the app to have the call and do the same.
        main.removeCallbacks(expire)
        main.postDelayed(expire, TIMEOUT)
    }

    private fun end(context: Context) {
        main.removeCallbacks(expire)
        if (ringing != null) context.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION)
        ringing = null
        action = null
        if (!ConnectionService.callBusy) CallScreen.set(show = false, wake = false)
        ConnectionService.stopIfIdle(context)
    }

    private fun notification(context: Context, call: String): Notification {
        val manager = context.getSystemService(NotificationManager::class.java)
        val ringtone = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        val vibration = longArrayOf(0, 900, 700, 900, 1500)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "Incoming calls while asleep", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Rings when a friend calls while OurNet is closed or the phone is asleep"
                    setSound(
                        ringtone,
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build()
                    )
                    enableVibration(true)
                    vibrationPattern = vibration
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                }
            )
        }
        fun open(code: Int, action: String?) = PendingIntent.getActivity(
            context, code,
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(EXTRA_CALL, call)
                .apply { if (action != null) putExtra(EXTRA_ACTION, action) },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val show = open(0x63616c6c, null)
        val answer = open(0x63616c6d, "answer")
        val decline = PendingIntent.getBroadcast(
            context, 0x63616c6e,
            Intent(context, Decline::class.java).putExtra(EXTRA_CALL, call),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        // The caller's name is not in the push (the server never learns who
        // calls whom); the app's notification shows it once it has the call.
        val title = "Incoming OurNet call"
        @Suppress("DEPRECATION")
        val builder = (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(context, CHANNEL) else Notification.Builder(context)
                .setPriority(Notification.PRIORITY_MAX)
                .setSound(ringtone, AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE).build())
                .setVibrate(vibration))
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText("Connecting to your friend…")
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(show)
            .setFullScreenIntent(show, true)
            .setOngoing(true)
            .setAutoCancel(false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) builder.setTimeoutAfter(TIMEOUT)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setStyle(
                Notification.CallStyle.forIncomingCall(Person.Builder().setName(title).build(), decline, answer)
            )
        } else {
            @Suppress("DEPRECATION")
            builder.addAction(Notification.Action.Builder(null, "Decline", decline).build())
            @Suppress("DEPRECATION")
            builder.addAction(Notification.Action.Builder(null, "Answer", answer).build())
        }
        // Rings and vibrates until answered, declined or cancelled.
        return builder.build().apply { flags = flags or Notification.FLAG_INSISTENT }
    }

    /** Decline on the notification: stops ringing; the app declines the offer when it arrives. */
    class Decline : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val call = intent.getStringExtra(EXTRA_CALL) ?: return
            act(context.applicationContext, call, "decline")
        }
    }
}
