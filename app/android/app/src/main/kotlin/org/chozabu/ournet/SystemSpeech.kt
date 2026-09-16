package org.chozabu.ournet

import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Optional transcription through the system speech service, which may send
 * audio to its provider. Chosen explicitly by the person, never by default.
 * Needs Android 13 to read audio from a file rather than the microphone, so
 * an existing recording can be transcribed. Live transcription while
 * recording is handled by [LiveSpeech]. */
object SystemSpeech {
    fun attach(context: Context, channel: MethodChannel) {
        val live = LiveSpeech(context, channel)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "liveStatus" -> live.status(call.argument<String>("language") ?: "auto", result)
                "liveStart" -> live.start(call.argument<String>("path")!!, call.argument<String>("language") ?: "auto",
                    call.argument<String>("source"), call.argument<String>("engine") ?: "auto", result)
                "liveStop" -> live.stop((call.argument<Int>("settle") ?: 2000).toLong(), result)
                "liveCancel" -> live.cancel(result)
                "available" -> result.success(
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                        SpeechRecognizer.isRecognitionAvailable(context))
                "transcribe" -> {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                        result.error("unsupported", "The system speech service needs Android 13 or later.", null)
                    } else {
                        transcribe(context, call.argument<String>("path")!!, call.argument<String>("language") ?: "auto", result)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun transcribe(context: Context, path: String, language: String, result: MethodChannel.Result) {
        val file = File(path)
        val input = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        val recognizer = SpeechRecognizer.createSpeechRecognizer(context)
        val text = StringBuilder()
        var finished = false
        fun finish(error: String?) {
            if (finished) return
            finished = true
            recognizer.destroy()
            input.close()
            if (error == null) result.success(text.toString().trim()) else result.error("speech", error, null)
        }
        fun collect(bundle: Bundle?) {
            val best = bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
            if (!best.isNullOrBlank()) text.append(best.trim()).append(' ')
        }
        recognizer.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onPartialResults(partialResults: Bundle?) {}
            override fun onEvent(eventType: Int, params: Bundle?) {}
            override fun onSegmentResults(segmentResults: Bundle) { collect(segmentResults) }
            override fun onEndOfSegmentedSession() { finish(null) }
            override fun onResults(results: Bundle?) { collect(results); finish(null) }
            override fun onError(error: Int) {
                if (error == SpeechRecognizer.ERROR_NO_MATCH || error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT) finish(null)
                else finish("The system speech service stopped (error $error).")
            }
        })
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, speechLocale(language))
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, input)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, 16000)
            putExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION, RecognizerIntent.EXTRA_AUDIO_SOURCE)
        }
        recognizer.startListening(intent)
    }
}
