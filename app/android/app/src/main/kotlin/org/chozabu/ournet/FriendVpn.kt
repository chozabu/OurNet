package org.chozabu.ournet

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import io.flutter.plugin.common.MethodChannel

/**
 * The virtual network interface a VPN plugin sends packets through (see
 * PLUGINS.md). Android asks the person once; the interface's descriptor
 * then goes to the native plugin host, which reads and writes packets
 * itself. Dart only asks for it ("open") and lets it go ("close").
 */
class FriendVpn : VpnService() {
    override fun onCreate() {
        super.onCreate()
        running = this
        val ready = waiting.toList()
        waiting.clear()
        ready.forEach { it(this) }
    }

    override fun onDestroy() {
        if (running === this) running = null
        super.onDestroy()
    }

    // The person switched it off in Android's settings, or another VPN took over.
    override fun onRevoke() {
        if (running === this) running = null
        stopSelf()
    }

    private fun establish(address: String, prefix: Int, routes: List<String>, mtu: Int): Int {
        val builder = Builder()
            .setSession("OurNet friend network")
            .setMtu(mtu)
            .addAddress(address, prefix)
        // OurNet's own sockets stay off the interface. Its connections carry
        // the network's packets, so through it they would carry themselves,
        // and the app would see the interface as a new default network and
        // rebuild its connections each time the network opened.
        try {
            builder.addDisallowedApplication(packageName)
        } catch (e: Exception) {
        }
        for (route in routes) {
            val (ip, length) = route.split("/").let { it[0] to (it.getOrNull(1)?.toInt() ?: 32) }
            builder.addRoute(ip, length)
        }
        val iface = builder.establish() ?: throw IllegalStateException("Android did not open the interface")
        // The native host owns it from here, and closes it.
        return iface.detachFd()
    }

    companion object {
        private const val CONSENT = 0x0E7A
        private var running: FriendVpn? = null
        private val waiting = mutableListOf<(FriendVpn) -> Unit>()
        private var consent: ((Boolean) -> Unit)? = null

        fun attach(activity: Activity, channel: MethodChannel) {
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "open" -> {
                        val address = call.argument<String>("address")
                        val prefix = call.argument<Int>("prefix") ?: 32
                        val mtu = call.argument<Int>("mtu") ?: 1280
                        val routes = call.argument<List<String>>("routes") ?: emptyList()
                        if (address == null) {
                            result.error("vpn", "No address", null)
                            return@setMethodCallHandler
                        }
                        fun start() {
                            val use = { vpn: FriendVpn ->
                                try {
                                    result.success(vpn.establish(address, prefix, routes, mtu))
                                } catch (e: Exception) {
                                    result.error("vpn", e.message, null)
                                }
                            }
                            val vpn = running
                            if (vpn != null) use(vpn) else {
                                waiting.add(use)
                                activity.startService(Intent(activity, FriendVpn::class.java))
                            }
                        }
                        val ask = VpnService.prepare(activity)
                        if (ask == null) start() else {
                            consent = { granted ->
                                if (granted) start() else result.error("vpn", "Not allowed", null)
                            }
                            activity.startActivityForResult(ask, CONSENT)
                        }
                    }
                    "close" -> {
                        running?.stopSelf()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        /** True when [requestCode] was the VPN consent this asked for. */
        fun activityResult(requestCode: Int, resultCode: Int): Boolean {
            if (requestCode != CONSENT) return false
            consent?.invoke(resultCode == Activity.RESULT_OK)
            consent = null
            return true
        }
    }
}
