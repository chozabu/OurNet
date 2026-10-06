package org.chozabu.ournet

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * "Stay connected": a foreground service that keeps OurNet's process, and
 * its Flutter engine, running while the app is in the background or swiped
 * away, so the app stays online for friends as if it were open. The engine
 * is kept in [FlutterEngineCache] under [ENGINE]; the activity reuses it
 * rather than starting a second one. If Android starts the service without
 * the activity (after a restart or an update), the service starts the engine.
 */
class ConnectionService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // A call keeps the service while it lasts, even with "Stay connected"
        // off, so the microphone and camera keep working with the screen off.
        if (!enabled(this) && !inCall) {
            stopSelf()
            return START_NOT_STICKY
        }
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "Connection", NotificationManager.IMPORTANCE_MIN).apply {
                    description = "Shown while OurNet stays connected to your friends"
                    setShowBadge(false)
                }
            )
        }
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(this, CHANNEL) else Notification.Builder(this)
        val notification = builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(if (inCall) "In an OurNet call" else "Connected to friends")
            .setContentText(
                if (inCall) "Tap to return to the call."
                else "Messages and calls arrive straight away. Turn off in Settings."
            )
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Location lets live location sharing keep reading the position,
            // and the microphone (with the camera for video) keeps a call
            // working, while the app is in the background. Android refuses
            // these when the service starts with the app out of sight (after
            // a restart, or a call while asleep): each refused set is dropped
            // in turn. Location resumes the next time the app is opened; a
            // call asks again once it is on screen.
            val special = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0
            val location = if (locationAllowed()) ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION else 0
            val call = callTypes()
            val candidates = listOf(special or location or call, special or call, special or location, special).distinct()
            var started = special
            for ((i, types) in candidates.withIndex()) {
                try {
                    startForeground(NOTIFICATION, notification, types)
                    started = types
                    break
                } catch (e: Exception) {
                    if (i == candidates.lastIndex) throw e
                    Log.w(TAG, "Service types $types refused: $e")
                }
            }
            locationType = started and ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION != 0
            callType = started and ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE != 0
        } else {
            startForeground(NOTIFICATION, notification)
            locationType = locationAllowed()
            callType = inCall
        }
        running = true
        engine(applicationContext)
        return START_STICKY
    }

    private fun granted(permission: String) =
        checkSelfPermission(permission) == android.content.pm.PackageManager.PERMISSION_GRANTED

    private fun locationAllowed(): Boolean =
        granted(android.Manifest.permission.ACCESS_FINE_LOCATION) ||
            granted(android.Manifest.permission.ACCESS_COARSE_LOCATION)

    /** The microphone, and for video the camera, while a call lasts. */
    private fun callTypes(): Int {
        if (!inCall || Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return 0
        var types = 0
        if (granted(android.Manifest.permission.RECORD_AUDIO)) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        if (callVideo && granted(android.Manifest.permission.CAMERA)) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
        return types
    }

    override fun onDestroy() {
        running = false
        locationType = false
        callType = false
        super.onDestroy()
    }

    /** Starts the service after the phone restarts or OurNet is updated. */
    class Starter : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == Intent.ACTION_BOOT_COMPLETED ||
                intent.action == Intent.ACTION_MY_PACKAGE_REPLACED
            ) start(context)
        }
    }

    companion object {
        const val ENGINE = "ournet-main"
        private const val CHANNEL = "connection"
        private const val NOTIFICATION = 7
        private const val PREFS = "ournet-connection"
        private const val TAG = "ConnectionService"
        private var running = false

        /** Whether the running service may read location in the background. */
        private var locationType = false

        /** A call is in progress or being placed; [callVideo] when it may use the camera. */
        private var inCall = false
        private var callVideo = false

        /** Whether the running service may use the microphone in the background. */
        private var callType = false

        private var channel: MethodChannel? = null
        private var watching = false
        private var network: Network? = null
        private var lost = false

        /**
         * Tells the app when the default network changes (Wi-Fi to mobile
         * data, or back after losing it), so it rebuilds its connection on
         * the new one instead of waiting to be reopened. Registered once per
         * process; events go to the most recently attached engine.
         */
        private fun watchNetwork(context: Context) {
            if (watching) return
            watching = true
            val main = Handler(Looper.getMainLooper())
            try {
                context.getSystemService(ConnectivityManager::class.java)
                    .registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
                        override fun onAvailable(available: Network) {
                            main.post {
                                val changed = lost || (network != null && network != available)
                                network = available
                                lost = false
                                if (changed) channel?.invokeMethod("networkChanged", null)
                            }
                        }

                        override fun onLost(gone: Network) {
                            main.post { if (gone == network) lost = true }
                        }
                    })
            } catch (e: Exception) {
                watching = false
                Log.w(TAG, "Network changes unavailable: $e")
            }
        }

        private fun batteryRestricted(context: Context): Boolean =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                !context.getSystemService(PowerManager::class.java)
                    .isIgnoringBatteryOptimizations(context.packageName)

        private fun fullScreenAllowed(context: Context): Boolean =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE ||
                context.getSystemService(NotificationManager::class.java).canUseFullScreenIntent()

        fun enabled(context: Context) =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("enabled", false)

        private fun setEnabled(context: Context, on: Boolean) =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean("enabled", on).apply()

        /** [force] runs the service's start again while it is running, so it can take on a type it could not before (location, once permitted). */
        private fun start(context: Context, force: Boolean = false) {
            if ((running && !force) || (!enabled(context) && !inCall)) return
            try {
                val intent = Intent(context, ConnectionService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent)
                else context.startService(intent)
            } catch (e: Exception) {
                // Android refuses to start it from the background; the next
                // time OurNet opens starts it instead.
                Log.w(TAG, "Could not start: $e")
            }
        }

        /** The running engine, or a new one running the app's main(). */
        private fun engine(context: Context): FlutterEngine {
            val cache = FlutterEngineCache.getInstance()
            cache.get(ENGINE)?.let { return it }
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(context)
            loader.ensureInitializationComplete(context, null)
            val engine = FlutterEngine(context)
            // Cached before main() runs, so an activity opening meanwhile
            // attaches to it instead of running main() a second time.
            cache.put(ENGINE, engine)
            attach(context, engine)
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            return engine
        }

        /**
         * Lets the app turn the service on and off. Turning it on keeps
         * [engine] (the activity's, or the service's own) beyond its activity.
         */
        fun attach(context: Context, engine: FlutterEngine) {
            val connection = MethodChannel(engine.dartExecutor.binaryMessenger, "ournet/connection")
            channel = connection
            watchNetwork(context)
            connection
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "start" -> {
                            setEnabled(context, true)
                            FlutterEngineCache.getInstance().put(ENGINE, engine)
                            start(context, force = true)
                            result.success(null)
                        }
                        "stop" -> {
                            setEnabled(context, false)
                            // A call in progress keeps it until the call ends.
                            if (!inCall) context.stopService(Intent(context, ConnectionService::class.java))
                            result.success(null)
                        }
                        "status" -> result.success(
                            mapOf(
                                "running" to running,
                                "location" to locationType,
                                "batteryRestricted" to batteryRestricted(context),
                                "fullScreen" to fullScreenAllowed(context),
                            )
                        )
                        // A call ringing, starting or ending. Ringing shows
                        // the call over the lock screen and turns the screen
                        // on; a call keeps the microphone (and camera) working
                        // with the screen off.
                        "call" -> {
                            val ringing = call.argument<Boolean>("ringing") == true
                            val active = call.argument<Boolean>("active") == true
                            val video = call.argument<Boolean>("video") == true
                            CallScreen.set(show = ringing || active, wake = ringing)
                            val changed = active != inCall || (active && video != callVideo)
                            inCall = active
                            callVideo = video
                            if (!active && !enabled(context)) {
                                context.stopService(Intent(context, ConnectionService::class.java))
                            } else if (changed || active != callType) {
                                // Also asks again for the microphone after
                                // Android refused it, once the call is on
                                // screen.
                                start(context, force = true)
                            }
                            result.success(null)
                        }
                        // Android 14 lets people turn off full-screen calls.
                        "fullScreenSettings" -> {
                            try {
                                context.startActivity(
                                    Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:${context.packageName}"))
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                )
                                result.success(true)
                            } catch (e: Exception) {
                                result.success(false)
                            }
                        }
                        // The app's own settings page, where Battery is set to
                        // Unrestricted; asking directly needs a permission Play
                        // reserves for a few kinds of app.
                        "batterySettings" -> {
                            try {
                                context.startActivity(
                                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                )
                                result.success(true)
                            } catch (e: Exception) {
                                result.success(false)
                            }
                        }
                        else -> result.notImplemented()
                    }
                }
        }
    }
}
