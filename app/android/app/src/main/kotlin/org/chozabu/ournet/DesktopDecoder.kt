package org.chozabu.ournet

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.util.ArrayDeque

/**
 * Remote desktop viewing on Android (docs/REMOTE_DESKTOP.md): the stream's
 * H.264 goes to a hardware MediaCodec decoder that renders straight into a
 * Flutter texture. Dart hands over each frame as it arrives and reads the
 * figures back; pictures never pass through Dart.
 */
class DesktopDecoder private constructor(
    private val producer: TextureRegistry.SurfaceProducer,
) {
    private val thread = HandlerThread("ournet-desktop-decoder").apply { start() }
    private val handler = Handler(thread.looper)
    private val lock = Object()
    private val frames = ArrayDeque<Pair<ByteArray, Boolean>>()
    private val inputs = ArrayDeque<Int>()
    private var codec: MediaCodec? = null
    private var size = 0 to 0
    private var waitingForKey = true
    @Volatile private var decoded = 0L
    @Volatile private var wantsKey = false
    @Volatile private var error = ""
    @Volatile private var closed = false
    @Volatile private var decodeMicros = 0L
    private val queuedAt = HashMap<Long, Long>()

    init {
        // The surface goes when the app is in the background and comes back
        // new: start again on it, from a keyframe.
        producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceAvailable() {
                handler.post { if (!closed && size.first > 0) start() }
            }

            override fun onSurfaceCleanup() {
                // The surface is invalid once this returns: stop rendering first.
                val done = java.util.concurrent.CountDownLatch(1)
                handler.post {
                    stop()
                    done.countDown()
                }
                done.await(500, java.util.concurrent.TimeUnit.MILLISECONDS)
            }
        })
    }

    /** The stream's size, from its figures; a new size starts a new decoder. */
    fun resize(width: Int, height: Int) = handler.post {
        if (closed || width <= 0 || height <= 0 || size == width to height) return@post
        size = width to height
        producer.setSize(width, height)
        start()
    }

    fun push(data: ByteArray, key: Boolean): Boolean {
        synchronized(lock) {
            // The decoder has fallen behind: drop what waits, ask for a keyframe.
            if (frames.size >= 32) {
                frames.clear()
                waitingForKey = true
                wantsKey = true
                return false
            }
            frames.add(data to key)
        }
        handler.post { feed() }
        return true
    }

    private fun start() {
        stop()
        val (w, h) = size
        try {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h)
            if (Build.VERSION.SDK_INT >= 30) format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            format.setInteger(MediaFormat.KEY_PRIORITY, 0)
            val c = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            c.setCallback(object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                    if (codec !== this@DesktopDecoder.codec) return
                    synchronized(lock) { inputs.add(index) }
                    feed()
                }

                override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                    if (codec !== this@DesktopDecoder.codec) return
                    // Shown at once: nothing is held back to pace it.
                    codec.releaseOutputBuffer(index, info.size > 0)
                    if (info.size > 0) {
                        decoded++
                        queuedAt.remove(info.presentationTimeUs)?.let {
                            decodeMicros = (System.nanoTime() - it) / 1000
                        }
                    }
                }

                override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                    error = e.message ?: "Decoder error"
                    handler.post { restart() }
                }

                override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {}
            }, handler)
            c.configure(format, producer.surface, null, 0)
            codec = c
            c.start()
            synchronized(lock) {
                inputs.clear()
                waitingForKey = true
            }
            wantsKey = true
        } catch (e: Exception) {
            error = e.message ?: "Could not start the decoder"
            codec = null
        }
    }

    private fun restart() {
        if (closed) return
        start()
    }

    private fun stop() {
        val c = codec ?: return
        codec = null
        try { c.stop() } catch (_: Exception) {}
        try { c.release() } catch (_: Exception) {}
        queuedAt.clear()
    }

    private var time = 0L

    private fun feed() {
        val c = codec ?: return
        while (true) {
            val (index, frame) = synchronized(lock) {
                if (inputs.isEmpty() || frames.isEmpty()) return
                var next = frames.poll()!!
                // After a start or a gap, only a keyframe can be decoded.
                while (waitingForKey && !next.second) {
                    wantsKey = true
                    next = frames.poll() ?: return
                }
                waitingForKey = false
                inputs.poll()!! to next
            }
            try {
                val buffer = c.getInputBuffer(index) ?: continue
                buffer.clear()
                if (frame.first.size > buffer.capacity()) {
                    synchronized(lock) { waitingForKey = true }
                    wantsKey = true
                    c.queueInputBuffer(index, 0, 0, time, 0)
                    continue
                }
                buffer.put(frame.first)
                time += 16_666
                queuedAt[time] = System.nanoTime()
                if (queuedAt.size > 64) queuedAt.clear()
                c.queueInputBuffer(index, 0, frame.first.size, time, if (frame.second) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
            } catch (e: Exception) {
                error = e.message ?: "Decoder error"
                handler.post { restart() }
                return
            }
        }
    }

    fun status(): Map<String, Any> {
        val key = wantsKey
        wantsKey = false
        return mapOf(
            "decoded" to decoded,
            "decodeMicros" to decodeMicros,
            "wantsKey" to key,
            "error" to error,
        )
    }

    fun close() {
        closed = true
        handler.post {
            stop()
            producer.release()
            thread.quitSafely()
        }
    }

    companion object {
        private val decoders = HashMap<Long, DesktopDecoder>()

        fun attach(engine: FlutterEngine) {
            val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "ournet/desktop")
            channel.setMethodCallHandler { call, result ->
                val handle = (call.argument<Number>("handle"))?.toLong() ?: 0L
                when (call.method) {
                    "create" -> {
                        val producer = engine.renderer.createSurfaceProducer()
                        val decoder = DesktopDecoder(producer)
                        decoders[producer.id()] = decoder
                        result.success(mapOf("texture" to producer.id(), "handle" to producer.id()))
                    }
                    "size" -> {
                        decoders[handle]?.resize(
                            call.argument<Number>("width")?.toInt() ?: 0,
                            call.argument<Number>("height")?.toInt() ?: 0,
                        )
                        result.success(null)
                    }
                    "frame" -> {
                        val data = call.argument<ByteArray>("data")
                        val key = call.argument<Boolean>("key") ?: false
                        result.success(data != null && decoders[handle]?.push(data, key) == true)
                    }
                    "status" -> result.success(decoders[handle]?.status())
                    "dispose" -> {
                        decoders.remove(handle)?.close()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }
}
