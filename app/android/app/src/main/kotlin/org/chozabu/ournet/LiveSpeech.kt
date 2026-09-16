package org.chozabu.ournet

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min

/** Records a voice note while the system speech service transcribes it live.
 * The audio is captured here rather than by the recorder plugin so one
 * microphone stream feeds both the saved file and the recognizer, which reads
 * raw samples from a pipe (Android 13+). The recording is kept even if
 * recognition fails; the caller then transcribes the file instead. */
class LiveSpeech(private val context: Context, private val channel: MethodChannel) {
    private var session: Any? = null

    fun available() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
        SpeechRecognizer.isRecognitionAvailable(context)

    /** Replies with `available`, and `onDevice` plus the `locale` to use when
     * the phone's on-device recognizer has [language] installed, so audio
     * need not leave the phone. A supported but missing language is offered
     * for download once per language: the system shows a dialog, and
     * dismissing it resumes the app, which checks again. */
    fun status(language: String, result: MethodChannel.Result) {
        if (!available()) return result.success(mapOf("available" to false))
        val none = mapOf("available" to true, "onDevice" to false)
        if (!SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) return result.success(none)
        val main = Handler(Looper.getMainLooper())
        val wanted = speechLocale(language)
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).putExtra(RecognizerIntent.EXTRA_LANGUAGE, wanted)
        val recognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        var replied = false
        fun reply(value: Map<String, Any>) {
            if (replied) return
            replied = true
            result.success(value)
            // Give a model download time to reach the service.
            main.postDelayed({ recognizer.destroy() }, 5_000)
        }
        main.postDelayed({ reply(none) }, 3_000)
        recognizer.checkRecognitionSupport(intent, context.mainExecutor, object : android.speech.RecognitionSupportCallback {
            override fun onSupportResult(support: android.speech.RecognitionSupport) {
                val installed = support.installedOnDeviceLanguages
                val language = wanted.substringBefore('-')
                val chosen = installed.firstOrNull { it.equals(wanted, true) }
                    ?: installed.firstOrNull { it.substringBefore('-').equals(language, true) }
                val offered = context.getSharedPreferences("live_speech", Context.MODE_PRIVATE)
                if (chosen == null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
                    support.supportedOnDeviceLanguages.any { it.substringBefore('-').equals(language, true) } &&
                    !offered.getBoolean("download_offered/$wanted", false)) {
                    offered.edit().putBoolean("download_offered/$wanted", true).apply()
                    runCatching { recognizer.triggerModelDownload(intent) }
                }
                Log.i(TAG, "on-device languages ${installed.joinToString()}; using ${chosen ?: "service"}")
                reply(if (chosen == null) none else mapOf("available" to true, "onDevice" to true, "locale" to chosen))
            }
            override fun onError(error: Int) {
                Log.i(TAG, "on-device support check failed ($error)")
                reply(none)
            }
        })
    }

    /** Starts recording to [path] (without extension; `.m4a` or `.wav` is
     * added). [source] replaces the microphone with raw 16 kHz mono PCM, paced
     * in real time, for tests. [engine] is `device`, `cloud` or `auto`
     * (on-device when the phone offers it). */
    fun start(path: String, language: String, source: String?, engine: String, result: MethodChannel.Result) {
        if (!available()) return result.error("unsupported", "Live transcription needs Android 13 or later with a speech service.", null)
        if (source == null && context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            return result.error("permission", "OurNet needs microphone access to record.", null)
        }
        (session as? Session)?.cancel()
        try {
            session = Session(path, language, source?.let(::File), engine)
            result.success(null)
        } catch (e: Exception) {
            Log.e(TAG, "start failed", e)
            session = null
            result.error("speech", "Recording is unavailable: ${e.message ?: e}", null)
        }
    }

    /** Stops recording at once. Replies when the file is complete and the
     * recognizer has given its final words, or after [settle] milliseconds
     * with the words heard so far. */
    fun stop(settle: Long, result: MethodChannel.Result) {
        val current = session as? Session ?: return result.error("speech", "Nothing is recording.", null)
        session = null
        current.stop(settle, result)
    }

    fun cancel(result: MethodChannel.Result) {
        (session as? Session)?.cancel()
        session = null
        result.success(null)
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private inner class Session(path: String, language: String, private val source: File?, engine: String) {
        private val main = Handler(Looper.getMainLooper())
        private val record: AudioRecord?
        private val output: Output
        private val pipe = ParcelFileDescriptor.createPipe()
        private val onDevice = engine == "device" ||
            (engine == "auto" && SpeechRecognizer.isOnDeviceRecognitionAvailable(context))
        private val recognizer = if (onDevice) SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
            else SpeechRecognizer.createSpeechRecognizer(context)
        private val feed = LinkedBlockingQueue<ByteArray>()
        private val queued = AtomicLong()
        private val began = SystemClock.elapsedRealtime()
        private var frames = 0L

        @Volatile private var running = true
        @Volatile private var cancelled = false
        @Volatile private var feeding = true

        // Main thread only.
        private val committed = StringBuilder()
        private var partial = ""
        private var stoppedAt = 0L
        private var recognitionDone = false
        private var recognitionFailed = false
        private var recordingDone = false
        private var recordingError: String? = null
        private var stopResult: MethodChannel.Result? = null

        private val listener = object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {
                log("ready")
                if (!cancelled && stopResult == null) channel.invokeMethod("liveReady", null)
            }
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onEvent(eventType: Int, params: Bundle?) {}
            override fun onPartialResults(results: Bundle?) {
                partial = best(results) ?: return
                send()
            }
            override fun onSegmentResults(results: Bundle) {
                best(results)?.let { committed.append(it).append(' ') }
                partial = ""
                log("segment")
                send()
            }
            override fun onResults(results: Bundle?) {
                best(results)?.let { committed.append(it).append(' ') }
                partial = ""
                log("results")
                done()
            }
            override fun onEndOfSegmentedSession() {
                log("end of session")
                done()
            }
            override fun onError(error: Int) {
                log("error $error")
                if (recognitionDone || cancelled) return
                if (error == SpeechRecognizer.ERROR_NO_MATCH || error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT) {
                    // A silent stretch; a segmented session keeps listening. If it
                    // did end, the growing backlog is noticed by capture().
                    if (stopResult != null) done()
                    return
                }
                // After Stop, the text heard so far covers the recording.
                if (stopResult == null) {
                    recognitionFailed = true
                    channel.invokeMethod("liveError", mapOf("message" to "The speech service stopped (error $error). Recording continues; the note is transcribed afterwards."))
                }
                stopFeeding()
                done()
            }
        }

        init {
            @SuppressLint("MissingPermission")
            val created = if (source != null) null else AudioRecord(MediaRecorder.AudioSource.MIC, RATE,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                max(AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT), RATE))
            record = created
            try {
                check(record == null || record.state == AudioRecord.STATE_INITIALIZED) { "the microphone could not be opened" }
                output = Output.open(path)
                recognizer.setRecognitionListener(listener)
                recognizer.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE, speechLocale(language))
                    putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, pipe[0])
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, SPEECH_RATE)
                    putExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION, RecognizerIntent.EXTRA_AUDIO_SOURCE)
                })
                record?.startRecording()
            } catch (e: Exception) {
                record?.release()
                recognizer.destroy()
                pipe.forEach { runCatching { it.close() } }
                throw e
            }
            log("started (${if (onDevice) "on device" else "service"}, ${output.mime})")
            Thread(::capture, "ournet-live-record").start()
            Thread(::pump, "ournet-live-feed").start()
        }

        fun stop(settle: Long, result: MethodChannel.Result) {
            stopResult = result
            stoppedAt = SystemClock.elapsedRealtime()
            running = false
            // Waiting longer for the last words must not hold the note back.
            main.postDelayed({
                log("settle timeout")
                recognitionDone = true
                finish()
            }, settle)
        }

        fun cancel() {
            cancelled = true
            running = false
            stopFeeding()
            recognizer.cancel()
            recognizer.destroy()
        }

        /** Reads the microphone, writes the file and queues speech for the recognizer. */
        private fun capture() {
            val buffer = ByteArray(RATE / 10 * 2) // 100 ms
            val input = source?.let(::FileInputStream)
            val sourceBuffer = ByteArray(buffer.size / 3)
            try {
                while (running) {
                    val count = if (input == null) record!!.read(buffer, 0, buffer.size) else {
                        // Real-time pacing; the test source is 16 kHz, so each
                        // sample repeats, and silence follows the end of the file.
                        Thread.sleep(max(0L, began + frames * 1000 / RATE - SystemClock.elapsedRealtime()))
                        val read = max(0, input.read(sourceBuffer)) and 1.inv()
                        buffer.fill(0)
                        for (i in 0 until read / 2) for (j in 0 until 3) {
                            buffer[(i * 3 + j) * 2] = sourceBuffer[i * 2]
                            buffer[(i * 3 + j) * 2 + 1] = sourceBuffer[i * 2 + 1]
                        }
                        buffer.size
                    }
                    if (count < 0) throw IOException("the microphone stopped ($count)")
                    if (count == 0) continue
                    frames += count / 2
                    level(buffer, count)
                    val speech = downsample(buffer, count)
                    output.write(buffer, count, speech)
                    if (feeding) {
                        if (queued.addAndGet(speech.size.toLong()) <= MAX_BACKLOG) feed.put(speech)
                        else {
                            stopFeeding()
                            main.post { stalled() }
                        }
                    }
                }
                // Let the recognizer hear the end while the file is finalised.
                feed.put(END)
                output.close()
            } catch (e: Exception) {
                Log.e(TAG, "recording failed", e)
                if (!cancelled) main.post { recordingError = "Recording failed: ${e.message ?: e}" }
                output.abandon()
            } finally {
                runCatching { record?.stop() }
                record?.release()
                input?.close()
                feed.put(END)
                if (cancelled) output.file.delete()
                main.post { recordingDone = true; finish() }
            }
        }

        /** Writes queued samples to the recognizer's pipe, closing it at the end. */
        private fun pump() {
            ParcelFileDescriptor.AutoCloseOutputStream(pipe[1]).use { out ->
                try {
                    while (true) {
                        val chunk = feed.take()
                        if (chunk === END) break
                        queued.addAndGet(-chunk.size.toLong())
                        if (feeding) out.write(chunk)
                    }
                } catch (_: IOException) {
                    feeding = false
                }
            }
            runCatching { pipe[0].close() }
        }

        private fun stopFeeding() {
            feeding = false
            feed.clear()
            queued.set(0)
            feed.put(END)
            // Unblocks a write to a recognizer that stopped reading.
            runCatching { pipe[0].close() }
        }

        /** The recognizer stopped reading; the file is transcribed afterwards instead. */
        private fun stalled() {
            if (recognitionDone || cancelled) return
            recognitionFailed = true
            if (stopResult == null) channel.invokeMethod("liveError", mapOf("message" to "The speech service stopped listening. Recording continues; the note is transcribed afterwards."))
            recognizer.cancel()
            done()
        }

        private fun level(buffer: ByteArray, count: Int) {
            var peak = 1
            for (i in 0 until count - 1 step 2) {
                peak = max(peak, abs((buffer[i].toInt() and 0xff) or (buffer[i + 1].toInt() shl 8)))
            }
            val decibels = 20 * log10(peak / 32768.0)
            main.post { if (!cancelled && stopResult == null) channel.invokeMethod("liveLevel", mapOf("level" to decibels)) }
        }

        private fun transcript() = (committed.toString() + partial).trim()

        private fun finish() {
            val result = stopResult ?: return
            if (!recordingDone || !recognitionDone) return
            stopResult = null
            main.removeCallbacksAndMessages(null)
            recognizer.destroy()
            log("finished ${SystemClock.elapsedRealtime() - stoppedAt} ms after stop: ${transcript()}")
            val error = recordingError
            if (error != null) {
                output.file.delete()
                result.error("speech", error, null)
            } else {
                // Null text asks the caller to transcribe the saved file instead.
                result.success(mapOf(
                    "text" to if (recognitionFailed) null else transcript(),
                    "duration" to frames * 1000 / RATE,
                    "path" to output.file.path,
                    "mime" to output.mime,
                ))
            }
        }

        private fun best(results: Bundle?) =
            results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.trim()?.takeIf { it.isNotEmpty() }

        private fun send() {
            if (!cancelled && stopResult == null) channel.invokeMethod("livePartial", mapOf("text" to transcript()))
        }

        private fun done() {
            recognitionDone = true
            finish()
        }

        private fun log(message: String) { Log.i(TAG, "[${SystemClock.elapsedRealtime() - began} ms] $message") }
    }

    /** The saved recording: AAC, or WAV if the phone's encoder cannot be set
     * up. (Android 17 refuses encoders configured without
     * CONFIGURE_FLAG_ENCODE, which is how this fallback was first needed.) */
    private abstract class Output(val file: File, val mime: String) {
        /** [pcm] is 48 kHz; [speech] the same audio at 16 kHz. */
        abstract fun write(pcm: ByteArray, count: Int, speech: ByteArray)
        abstract fun close()
        abstract fun abandon()

        companion object {
            fun open(path: String): Output = try {
                Aac(File("$path.m4a"))
            } catch (e: Exception) {
                Log.w(TAG, "AAC encoder unavailable, recording WAV", e)
                File("$path.m4a").delete()
                Wav(File("$path.wav"))
            }
        }
    }

    private class Aac(file: File) : Output(file, "audio/mp4") {
        private val encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        private val muxer: MediaMuxer
        private val info = MediaCodec.BufferInfo()
        private var track = -1
        private var frames = 0L

        init {
            try {
                encoder.configure(MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, RATE, 1).apply {
                    setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                    setInteger(MediaFormat.KEY_BIT_RATE, 48000)
                }, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                encoder.start()
                muxer = MediaMuxer(file.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            } catch (e: Exception) {
                encoder.release()
                throw e
            }
        }

        override fun write(pcm: ByteArray, count: Int, speech: ByteArray) = encode(pcm, count, false)

        override fun close() {
            try {
                encode(ByteArray(0), 0, true)
                muxer.stop()
            } finally {
                release()
            }
        }

        override fun abandon() = release()

        private fun release() {
            runCatching { encoder.stop() }
            encoder.release()
            runCatching { muxer.release() }
        }

        private fun encode(bytes: ByteArray, length: Int, end: Boolean) {
            var offset = 0
            while (offset < length || end) {
                val index = encoder.dequeueInputBuffer(10_000)
                if (index >= 0) {
                    val input = encoder.getInputBuffer(index)!!
                    input.clear()
                    val count = min(input.remaining(), length - offset) and 1.inv()
                    input.put(bytes, offset, count)
                    val last = end && offset + count >= length
                    encoder.queueInputBuffer(index, 0, count, frames * 1_000_000L / RATE,
                        if (last) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0)
                    offset += count
                    frames += count / 2
                    if (last) return drain(true)
                }
                drain(false)
            }
        }

        private fun drain(untilEnd: Boolean) {
            var waits = 0
            while (true) {
                val index = encoder.dequeueOutputBuffer(info, if (untilEnd) 10_000 else 0)
                if (index == MediaCodec.INFO_TRY_AGAIN_LATER) {
                    if (!untilEnd || ++waits > 500) return
                } else if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    track = muxer.addTrack(encoder.outputFormat)
                    muxer.start()
                } else if (index >= 0) {
                    val output = encoder.getOutputBuffer(index)!!
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                    if (info.size > 0 && track >= 0) {
                        output.position(info.offset)
                        output.limit(info.offset + info.size)
                        muxer.writeSampleData(track, output, info)
                    }
                    encoder.releaseOutputBuffer(index, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
            }
        }
    }

    /** 16 kHz mono 16-bit WAV, about 1.9 MB a minute. */
    private class Wav(file: File) : Output(file, "audio/wav") {
        private val out = RandomAccessFile(file, "rw").apply {
            setLength(0)
            write(ByteArray(44))
        }
        private var bytes = 0L

        override fun write(pcm: ByteArray, count: Int, speech: ByteArray) {
            out.write(speech)
            bytes += speech.size
        }

        override fun close() {
            out.use {
                it.seek(0)
                it.write(header(bytes))
            }
        }

        override fun abandon() {
            runCatching { out.close() }
        }

        private fun header(data: Long): ByteArray = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray()).putInt((36 + data).toInt()).put("WAVE".toByteArray())
            put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(1)
                .putInt(SPEECH_RATE).putInt(SPEECH_RATE * 2).putShort(2).putShort(16)
            put("data".toByteArray()).putInt(data.toInt())
        }.array()
    }

    private companion object {
        const val TAG = "LiveSpeech"
        /** Recorded rate; many AAC encoders refuse 16 kHz. */
        const val RATE = 48000
        const val SPEECH_RATE = 16000
        val END = ByteArray(0)
        /** 15 seconds of speech audio the recognizer has not read. */
        const val MAX_BACKLOG = 15L * SPEECH_RATE * 2

        /** 48 kHz to 16 kHz, averaging each group of three samples. */
        fun downsample(buffer: ByteArray, count: Int): ByteArray {
            val frames = count / 6
            val out = ByteArray(frames * 2)
            for (f in 0 until frames) {
                var sum = 0
                for (j in 0 until 3) {
                    val i = (f * 3 + j) * 2
                    sum += (buffer[i].toInt() and 0xff) or (buffer[i + 1].toInt() shl 8)
                }
                val sample = sum / 3
                out[f * 2] = sample.toByte()
                out[f * 2 + 1] = (sample shr 8).toByte()
            }
            return out
        }
    }
}

/** A full locale such as `en-GB`: on-device recognizers reject bare
 * language codes. The phone's own region is preferred. */
internal fun speechLocale(language: String): String {
    val device = java.util.Locale.getDefault()
    return if (language.contains('-')) language
        else if (language == "auto" || language == device.language) device.toLanguageTag()
        else java.util.Locale.forLanguageTag(language).let {
            if (it.country.isNotEmpty()) it.toLanguageTag() else java.util.Locale(language, when (language) {
                "en" -> "US"; "ja" -> "JP"; "ko" -> "KR"; "zh" -> "CN"; "hi" -> "IN"; "ar" -> "SA"
                "sv" -> "SE"; "uk" -> "UA"; else -> language.uppercase()
            }).toLanguageTag()
        }
}
