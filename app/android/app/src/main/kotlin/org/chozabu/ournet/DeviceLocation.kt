package org.chozabu.ournet

import android.annotation.SuppressLint
import android.content.Context
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * This device's position from Android's own LocationManager, without Google
 * Play services. The F-Droid build reads location through this
 * (app/fdroid/lib/services/device_position.dart); the other builds use the
 * geolocator plugin, so this is attached but unused there. The app checks
 * and asks for permission before listening.
 */
object DeviceLocation {
    private const val INTERVAL_MS = 20_000L
    private const val DISTANCE_M = 15f

    fun attach(context: Context, engine: FlutterEngine) {
        val messenger = engine.dartExecutor.binaryMessenger
        val manager = context.getSystemService(LocationManager::class.java)
        MethodChannel(messenger, "ournet/location").setMethodCallHandler { call, result ->
            when (call.method) {
                "enabled" -> result.success(manager != null && enabled(manager))
                "now" -> if (manager == null) result.success(null) else now(manager) { result.success(it?.let(::fix)) }
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, "ournet/location/fixes").setStreamHandler(object : EventChannel.StreamHandler {
            private var active: LocationListener? = null

            @SuppressLint("MissingPermission")
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                if (manager == null) {
                    events.error("location", "No location service", null)
                    return
                }
                val heard = listener { events.success(fix(it)) }
                try {
                    val providers = providers(manager)
                    if (providers.isEmpty()) {
                        events.error("location", "No location provider", null)
                        return
                    }
                    for (provider in providers) {
                        manager.requestLocationUpdates(provider, INTERVAL_MS, DISTANCE_M, heard, Looper.getMainLooper())
                    }
                    active = heard
                } catch (e: SecurityException) {
                    events.error("permission", e.message, null)
                }
            }

            override fun onCancel(arguments: Any?) {
                active?.let { manager?.removeUpdates(it) }
                active = null
            }
        })
    }

    private fun enabled(manager: LocationManager): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) manager.isLocationEnabled
        else providers(manager).isNotEmpty()

    /**
     * Android's own fused provider where there is one (12 and later, not
     * Google's), otherwise satellite and network positioning together.
     */
    private fun providers(manager: LocationManager): List<String> {
        val on = manager.getProviders(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && LocationManager.FUSED_PROVIDER in on) {
            return listOf(LocationManager.FUSED_PROVIDER)
        }
        return listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER).filter { it in on }
    }

    /** One fresh fix, or null; the app gives up after a time limit of its own. */
    @SuppressLint("MissingPermission")
    private fun now(manager: LocationManager, done: (Location?) -> Unit) {
        val main = Handler(Looper.getMainLooper())
        var answered = false
        val answer = { location: Location? ->
            main.post {
                if (!answered) {
                    answered = true
                    done(location)
                }
            }
        }
        try {
            val provider = providers(manager).firstOrNull()
            if (provider == null) {
                answer(null)
                return
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                manager.getCurrentLocation(provider, CancellationSignal(), { main.post(it) }) { answer(it) }
            } else {
                @Suppress("DEPRECATION")
                manager.requestSingleUpdate(provider, listener { answer(it) }, Looper.getMainLooper())
            }
        } catch (e: SecurityException) {
            answer(null)
        } catch (e: IllegalArgumentException) {
            answer(null)
        }
    }

    /** Implements every method: before Android 11 the others are abstract too. */
    private fun listener(heard: (Location) -> Unit) = object : LocationListener {
        override fun onLocationChanged(location: Location) = heard(location)
        @Deprecated("Deprecated in Java")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
        override fun onProviderEnabled(provider: String) {}
        override fun onProviderDisabled(provider: String) {}
    }

    private fun fix(location: Location): Map<String, Any?> = mapOf(
        "lat" to location.latitude,
        "lng" to location.longitude,
        "at" to location.time,
        "accuracy" to if (location.hasAccuracy()) location.accuracy.toDouble() else null,
        "heading" to if (location.hasBearing()) location.bearing.toDouble() else null,
        "speed" to if (location.hasSpeed()) location.speed.toDouble() else null,
    )
}
