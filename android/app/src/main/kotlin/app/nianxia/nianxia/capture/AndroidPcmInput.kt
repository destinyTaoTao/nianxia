package app.nianxia.nianxia.capture

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioRecordingConfiguration
import android.media.AudioRouting
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.util.concurrent.Executor

/** Synchronous bounded PCM delivery; the reader never queues a library of audio. */
class AndroidPcmInput(private val context: Context) : CaptureAudioSource {
    @Volatile private var running = false
    private var recorder: AudioRecord? = null
    private var reader: Thread? = null
    private val manager = context.getSystemService(AudioManager::class.java)
    private var focusRequest: AudioFocusRequest? = null
    private var focusListener: AudioManager.OnAudioFocusChangeListener? = null
    private var recordingCallback: AudioManager.AudioRecordingCallback? = null
    private var routeListener: AudioRouting.OnRoutingChangedListener? = null

    override fun start(onPcm: (ByteArray, Int) -> Unit, onError: (String) -> Unit) {
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            throw CaptureFailure("audio_permission")
        }
        val listener = AudioManager.OnAudioFocusChangeListener { change ->
            if (change < 0 && running) onError("audio_interrupted")
        }
        focusListener = listener
        val granted = if (Build.VERSION.SDK_INT >= 26) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setOnAudioFocusChangeListener(listener, Handler(Looper.getMainLooper())).build()
            focusRequest = request
            manager.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            manager.requestAudioFocus(listener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
        }
        if (granted != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) throw CaptureFailure("audio_focus")
        val minimum = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minimum <= 0) throw CaptureFailure("audio_format")
        val builder = AudioRecord.Builder().setAudioSource(MediaRecorder.AudioSource.MIC)
            .setAudioFormat(AudioFormat.Builder().setSampleRate(16000)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT).setChannelMask(AudioFormat.CHANNEL_IN_MONO).build())
            .setBufferSizeInBytes(maxOf(minimum * 4, 4096))
        if (Build.VERSION.SDK_INT >= 30) builder.setPrivacySensitive(true)
        val input = builder.build()
        recorder = input
        if (input.state != AudioRecord.STATE_INITIALIZED) throw CaptureFailure("audio_start")
        if (Build.VERSION.SDK_INT >= 29) {
            val callback = object : AudioManager.AudioRecordingCallback() {
                override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>) {
                    if (running && configs.any { it.clientAudioSessionId == input.audioSessionId && it.isClientSilenced }) {
                        onError("audio_interrupted")
                    }
                }
            }
            recordingCallback = callback
            input.registerAudioRecordingCallback(Executor { Handler(Looper.getMainLooper()).post(it) }, callback)
        }
        input.startRecording()
        if (input.recordingState != AudioRecord.RECORDSTATE_RECORDING) throw CaptureFailure("audio_start")
        running = true
        var previousRoute = input.routedDevice?.id
        val route = AudioRouting.OnRoutingChangedListener {
            val currentRoute = input.routedDevice?.id
            if (running && previousRoute != null && currentRoute != previousRoute) onError("audio_route_changed")
            previousRoute = currentRoute
        }
        routeListener = route
        input.addOnRoutingChangedListener(route, Handler(Looper.getMainLooper()))
        reader = Thread({
            val buffer = ByteArray(maxOf(minimum, 4096))
            try {
                while (running) {
                    val count = input.read(buffer, 0, buffer.size, AudioRecord.READ_BLOCKING)
                    if (!running) break
                    if (count > 0) onPcm(buffer, count)
                    else { onError("audio_read"); break }
                }
            } catch (_: Exception) {
                if (running) onError("audio_read")
            }
        }, "nianxia-pcm-reader").also { it.start() }
    }

    override fun stop() {
        running = false
        val input = recorder
        recorder = null
        try {
            if (input != null) {
                runCatching { input.stop() }
                val thread = reader
                if (thread != null && thread !== Thread.currentThread()) thread.join(2000)
                if (Build.VERSION.SDK_INT >= 29) recordingCallback?.let { input.unregisterAudioRecordingCallback(it) }
                routeListener?.let { input.removeOnRoutingChangedListener(it) }
                input.release()
                if (thread?.isAlive == true) {
                    thread.join(1000)
                    if (thread.isAlive) throw CaptureFailure("audio_release")
                }
            }
        } finally {
            reader = null
            recordingCallback = null
            routeListener = null
            if (Build.VERSION.SDK_INT >= 26) focusRequest?.let { manager.abandonAudioFocusRequest(it) }
            else {
                @Suppress("DEPRECATION")
                focusListener?.let { manager.abandonAudioFocus(it) }
            }
            focusRequest = null
            focusListener = null
        }
    }
}
