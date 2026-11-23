package org.chozabu.ournet

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The F-Droid build has no Firebase, so no push wake-up: "token" answers
 * null, as an unconfigured Firebase does in the other builds, and the app
 * keeps to the connection service and periodic checks. The real one is in
 * src/gms.
 */
object PushWake {
    fun attach(context: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "ournet/push").setMethodCallHandler { call, result ->
            when (call.method) {
                "token" -> result.success(null)
                "enable" -> result.success(null)
                "callAction" -> result.success(IncomingCall.takeAction(call.arguments as? String))
                else -> result.notImplemented()
            }
        }
    }
}
