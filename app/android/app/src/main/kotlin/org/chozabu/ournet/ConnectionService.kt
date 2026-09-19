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
import android.os.Build
import android.os.IBinder
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
            startForeground(NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION, notification)
        }
        running = true
        engine(applicationContext)
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
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

        fun enabled(context: Context) =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("enabled", false)

        private fun setEnabled(context: Context, on: Boolean) =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean("enabled", on).apply()

        private fun start(context: Context) {
            if (running || !enabled(context)) return
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
            MethodChannel(engine.dartExecutor.binaryMessenger, "ournet/connection")
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "start" -> {
                            setEnabled(context, true)
                            FlutterEngineCache.getInstance().put(ENGINE, engine)
                            start(context)
                            result.success(null)
                        }
                        "stop" -> {
                            setEnabled(context, false)
                            context.stopService(Intent(context, ConnectionService::class.java))
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                }
        }
    }
}
