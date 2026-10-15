package org.chozabu.ournet

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Push wake-up through Firebase Cloud Messaging: a friend's device asks
 * OurNet's push server to wake this phone, and the server sends an empty,
 * high-priority data message. Receiving one runs [WakeWorker], which syncs
 * as a background run does (or hands the sync to the app when it is
 * running). See docs/CONNECTIVITY.md.
 *
 * Firebase is configured from res/values/firebase.xml. With those values
 * empty Firebase never starts and none of this does anything.
 */
class PushWake : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        Handler(Looper.getMainLooper()).post { channel?.invokeMethod("token", token) }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        if (message.data["ournet"] == "wake") wake(applicationContext)
    }

    companion object {
        private const val TAG = "PushWake"
        private const val WORK = "ournet-wake"
        private var channel: MethodChannel? = null

        private fun configured(context: Context) = FirebaseApp.getApps(context).isNotEmpty()

        /** Lets the app read the FCM token and turn FCM on or off. */
        fun attach(context: Context, engine: FlutterEngine) {
            val push = MethodChannel(engine.dartExecutor.binaryMessenger, "ournet/push")
            channel = push
            push.setMethodCallHandler { call, result ->
                when (call.method) {
                    "token" -> {
                        if (!configured(context)) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        val messaging = FirebaseMessaging.getInstance()
                        // Off in the manifest, so no token exists until the
                        // person has push wake-up on.
                        messaging.isAutoInitEnabled = true
                        messaging.token.addOnCompleteListener { task ->
                            if (task.isSuccessful) result.success(task.result)
                            else result.error("fcm", task.exception?.message, null)
                        }
                    }
                    "enable" -> {
                        if (configured(context)) {
                            val on = call.arguments == true
                            val messaging = FirebaseMessaging.getInstance()
                            messaging.isAutoInitEnabled = on
                            if (!on) messaging.deleteToken()
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        /** Whether a wake run is going, and whether another wake came meanwhile. */
        @Volatile private var running = false
        @Volatile private var again = false

        private fun wake(context: Context) {
            if (running) {
                again = true
                return
            }
            // Expedited: a high-priority message lets the app start it at once.
            val request = OneTimeWorkRequestBuilder<WakeWorker>()
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(WORK, ExistingWorkPolicy.KEEP, request)
        }

        /**
         * Runs the app's `pushWakeMain` in an engine of its own until it says
         * it is done. That hands the sync to the app's engine when the app is
         * running, or opens the profile briefly when it is not.
         */
        private fun runDart(context: Context) {
            val main = Handler(Looper.getMainLooper())
            val done = CountDownLatch(1)
            var engine: FlutterEngine? = null
            main.post {
                try {
                    val loader = FlutterInjector.instance().flutterLoader()
                    loader.startInitialization(context)
                    loader.ensureInitializationComplete(context, null)
                    val started = FlutterEngine(context)
                    engine = started
                    MethodChannel(started.dartExecutor.binaryMessenger, "ournet/push-run")
                        .setMethodCallHandler { call, result ->
                            result.success(null)
                            if (call.method == "done") done.countDown()
                        }
                    started.dartExecutor.executeDartEntrypoint(
                        DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "pushWakeMain")
                    )
                } catch (e: Exception) {
                    Log.w(TAG, "Could not start: $e")
                    done.countDown()
                }
            }
            // A background run syncs, then answers peers for a few seconds.
            if (!done.await(4, TimeUnit.MINUTES)) Log.w(TAG, "Wake run did not finish")
            main.post { engine?.destroy() }
        }
    }

    class WakeWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
        override fun doWork(): Result {
            running = true
            try {
                do {
                    again = false
                    runDart(applicationContext)
                } while (again)
            } finally {
                running = false
            }
            return Result.success()
        }

        // Before Android 12 expedited work runs as a foreground service.
        override fun getForegroundInfo(): ForegroundInfo {
            val manager = applicationContext.getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.createNotificationChannel(
                    NotificationChannel("wake", "Receiving messages", NotificationManager.IMPORTANCE_MIN).apply {
                        setShowBadge(false)
                    }
                )
            }
            @Suppress("DEPRECATION")
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                Notification.Builder(applicationContext, "wake") else Notification.Builder(applicationContext)
            return ForegroundInfo(
                8,
                builder.setSmallIcon(R.mipmap.ic_launcher)
                    .setContentTitle("Receiving messages")
                    .setShowWhen(false)
                    .build()
            )
        }
    }
}
