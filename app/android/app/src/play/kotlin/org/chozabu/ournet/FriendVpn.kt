package org.chozabu.ournet

import android.app.Activity
import io.flutter.plugin.common.MethodChannel

/**
 * The Google Play build has no VpnService: Play refuses one for OurNet, whose
 * VPN is an optional plugin rather than the app's core function. "open"
 * reports that instead of asking Android; the full build's FriendVpn
 * (src/full) is the real one.
 */
object FriendVpn {
    fun attach(activity: Activity, channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> result.error("vpn", "This build of OurNet has no VPN", null)
                "close" -> result.success(null)
                else -> result.notImplemented()
            }
        }
    }

    fun activityResult(requestCode: Int, resultCode: Int): Boolean = false
}
