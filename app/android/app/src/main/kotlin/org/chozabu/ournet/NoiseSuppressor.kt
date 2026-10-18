package org.chozabu.ournet

import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.audio.AudioProcessingAdapter
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer

/** Puts the native library's RNNoise denoiser (native/rust/src/denoise.rs)
 * in flutter_webrtc's capture hook, after WebRTC's own echo cancelling and
 * noise suppression. Dart switches the denoiser on and off; while it is off
 * frames pass through untouched. */
object NoiseSuppressor : AudioProcessingAdapter.ExternalAudioFrameProcessing {
    @Volatile private var rate = 48000
    private var attached = false

    /** Denoises [frames] float samples in [buffer] in place; 1 if it did. */
    @JvmStatic external fun process(buffer: ByteBuffer, frames: Int, rate: Int): Int

    fun attach(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "attach") return@setMethodCallHandler result.notImplemented()
            if (attached) return@setMethodCallHandler result.success(null)
            val controller = FlutterWebRTCPlugin.sharedSingleton?.audioProcessingController
            if (controller == null) {
                return@setMethodCallHandler result.error("unavailable", "WebRTC is not initialised", null)
            }
            try {
                // Dart loaded it already; this binds [process] to it.
                System.loadLibrary("ournet_native")
            } catch (e: UnsatisfiedLinkError) {
                return@setMethodCallHandler result.error("unavailable", e.message, null)
            }
            controller.capturePostProcessing.addProcessor(this)
            attached = true
            result.success(null)
        }
    }

    override fun initialize(sampleRateHz: Int, numChannels: Int) {
        rate = sampleRateHz
    }

    override fun reset(newRate: Int) {
        rate = newRate
    }

    override fun process(numBands: Int, numFrames: Int, buffer: ByteBuffer) {
        process(buffer, numFrames, rate)
    }
}
