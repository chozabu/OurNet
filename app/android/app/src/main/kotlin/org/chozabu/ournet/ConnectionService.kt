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
        if (!enabled(this)) {
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
            .setContentTitle("Connected to friends")
            .setContentText("Messages and calls arrive straight away. Turn off in Settings.")
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val special = ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            var started = false
            if (locationAllowed()) {
                // Lets live location sharing keep reading the position while
                // the app is in the background. Android refuses this when the
                // service is started with the app out of sight (after a
                // restart); then it runs as before and location resumes the
                // next time the app is opened.
                try {
                    startForeground(NOTIFICATION, notification, special or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
                    started = true
                } catch (e: Exception) {
                    Log.w("OurNet", "Location service type refused: $e")
                }
            }
            if (!started) startForeground(NOTIFICATION, notification, special)
            locationType = started
        } else {
            startForeground(NOTIFICATION, notification)
            locationType = locationAllowed()
        }
        running = true
        engine(applicationContext)
        return START_STICKY
    }

    private fun locationAllowed(): Boolean =
        checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED ||
            checkSelfPermission(android.Manifest.permission.ACCESS_COARSE_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED

    override fun onDestroy() {
        running = false
        locationType = false
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

        fun enabled(context: Context) =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("enabled", false)

        private fun setEnabled(context: Context, on: Boolean) =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean("enabled", on).apply()

        /** [force] runs the service's start again while it is running, so it can take on a type it could not before (location, once permitted). */
        private fun start(context: Context, force: Boolean = false) {
            if ((running && !force) || !enabled(context)) return
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
                            context.stopService(Intent(context, ConnectionService::class.java))
                            result.success(null)
                        }
                        "status" -> result.success(
                            mapOf(
                                "running" to running,
                                "location" to locationType,
                                "batteryRestricted" to batteryRestricted(context),
                            )
                        )
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
