package com.dailightstudio.echomic

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * Bridges the Dart MethodChannel to the native Oboe engine via JNI.
 */
class AudioEnginePlugin : FlutterPlugin, MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var appContext: Context

    private var eventSink: EventChannel.EventSink? = null
    private var pollingHandler: android.os.Handler? = null
    private var expectedRunning = false

    // Fires just before the active output route disappears (e.g. wired
    // headset unplugged) and audio would otherwise fall back to the
    // built-in speaker -- stop immediately instead of letting the native
    // ErrorDisconnected auto-reconnect land on the speaker and howl into
    // the still-open mic.
    private var noisyReceiver: BroadcastReceiver? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
                startPolling()
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
                stopPolling()
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        stopPolling()
        eventSink = null
        EchoMicForegroundService.onStopFromNotification = null
        endSession()
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "start" -> {
                var ok = nativeStart()
                if (ok) {
                    try {
                        EchoMicForegroundService.start(appContext)
                    } catch (e: Exception) {
                        // Refused because the app is already in the background
                        // (Start tapped, then the app left before the setters
                        // finished). Without the FGS the mic must not stay on.
                        android.util.Log.w("AudioEnginePlugin", "mic FGS refused", e)
                        nativeStop()
                        ok = false
                    }
                }
                expectedRunning = ok
                if (ok) {
                    EchoMicForegroundService.onStopFromNotification = { endSession(reason = "user") }
                    registerNoisyReceiver()
                }
                result.success(ok)
            }
            "stop" -> {
                endSession()
                result.success(null)
            }
            "setGain" -> {
                val gain = (call.argument<Double>("gain") ?: 1.0).toFloat()
                nativeSetGain(gain)
                result.success(null)
            }
            "setEchoDelay" -> {
                val delayMs = (call.argument<Double>("delayMs") ?: 0.0).toFloat()
                nativeSetEchoDelay(delayMs)
                result.success(null)
            }
            "setEchoFeedback" -> {
                val feedback = (call.argument<Double>("feedback") ?: 0.0).toFloat()
                nativeSetEchoFeedback(feedback)
                result.success(null)
            }
            "setReverbMix" -> {
                val wet = (call.argument<Double>("mix") ?: 0.0).toFloat()
                nativeSetReverbWet(wet)
                result.success(null)
            }
            "setMasterVolume" -> {
                val gain = (call.argument<Double>("volume") ?: 1.0).toFloat()
                nativeSetMasterGain(gain)
                result.success(null)
            }
            "setGateThreshold" -> {
                val db = (call.argument<Double>("db") ?: -40.0).toFloat()
                nativeSetGateThreshold(db)
                result.success(null)
            }
            "setEQBand" -> {
                val band = call.argument<Int>("band") ?: 0
                val gainDb = (call.argument<Double>("gainDb") ?: 0.0).toFloat()
                nativeSetEQBand(band, gainDb)
                result.success(null)
            }
            "setBoost" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                nativeSetBoost(enabled)
                result.success(null)
            }
            "setFrequencyShift" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                nativeSetFrequencyShift(enabled)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun startPolling() {
        stopPolling()  // ensure a single polling loop even on repeated onListen
        pollingHandler = android.os.Handler(android.os.Looper.getMainLooper())
        val runnable = object : Runnable {
            override fun run() {
                val sink = eventSink ?: return
                val running = nativeIsRunning()
                // 상태 변화 감지: 시작을 기대했으나 엔진이 멈춘 경우
                if (expectedRunning && !running) {
                    // Native died on its own (e.g. a failed input read/
                    // reconnect) without going through stop(): the FGS
                    // notification would otherwise outlive the engine.
                    endSession(reason = "interrupted")
                }
                // 레벨 이벤트
                if (running) {
                    val rms = nativeGetRmsLevel()
                    sink.success(mapOf("type" to "level", "rms" to rms.toDouble()))
                }
                pollingHandler?.postDelayed(this, 50)
            }
        }
        pollingHandler?.post(runnable)
    }

    private fun stopPolling() {
        pollingHandler?.removeCallbacksAndMessages(null)
        pollingHandler = null
    }

    /**
     * The one way a session ends: engine, foreground service, noisy receiver.
     * [reason] non-null tells Dart it ended without Dart asking
     * ("user" = 정지 in the notification, "interrupted" = unplug/engine death).
     */
    private fun endSession(reason: String? = null) {
        nativeStop()
        expectedRunning = false
        EchoMicForegroundService.stop()
        unregisterNoisyReceiver()
        if (reason != null) {
            eventSink?.success(mapOf("type" to "state", "running" to false, "reason" to reason))
        }
    }

    // --- Stop before the route falls back to the speaker (fix: unplug-> howl) ---
    private fun registerNoisyReceiver() {
        if (noisyReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                endSession(reason = "interrupted")
            }
        }
        ContextCompat.registerReceiver(
            appContext,
            receiver,
            IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        noisyReceiver = receiver
    }

    private fun unregisterNoisyReceiver() {
        noisyReceiver?.let {
            appContext.unregisterReceiver(it)
            noisyReceiver = null
        }
    }

    // --- JNI entry points implemented in jni_bridge.cpp ---
    private external fun nativeStart(): Boolean
    private external fun nativeStop()
    private external fun nativeSetGain(gain: Float)
    private external fun nativeSetEchoDelay(delayMs: Float)
    private external fun nativeSetEchoFeedback(feedback: Float)
    private external fun nativeGetRmsLevel(): Float
    private external fun nativeIsRunning(): Boolean
    private external fun nativeSetReverbWet(wet: Float)
    private external fun nativeSetMasterGain(gain: Float)
    private external fun nativeSetGateThreshold(db: Float)
    private external fun nativeSetEQBand(band: Int, gainDb: Float)
    private external fun nativeSetBoost(enabled: Boolean)
    private external fun nativeSetFrequencyShift(enabled: Boolean)

    companion object {
        private const val CHANNEL = "com.dailightstudio.echomic/audio"
        private const val EVENT_CHANNEL = "com.dailightstudio.echomic/events"

        init {
            System.loadLibrary("echomic_engine")
        }
    }
}
