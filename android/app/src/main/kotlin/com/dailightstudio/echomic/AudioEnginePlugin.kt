package com.dailightstudio.echomic

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

    private var eventSink: EventChannel.EventSink? = null
    private var pollingHandler: android.os.Handler? = null
    private var expectedRunning = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
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
        nativeStop()
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "start" -> {
                val ok = nativeStart()
                expectedRunning = ok
                result.success(ok)
            }
            "stop" -> {
                nativeStop()
                expectedRunning = false
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
            else -> result.notImplemented()
        }
    }

    private fun startPolling() {
        pollingHandler = android.os.Handler(android.os.Looper.getMainLooper())
        val runnable = object : Runnable {
            override fun run() {
                val sink = eventSink ?: return
                val running = nativeIsRunning()
                // 상태 변화 감지: 시작을 기대했으나 엔진이 멈춘 경우
                if (expectedRunning && !running) {
                    sink.success(mapOf("type" to "state", "running" to false))
                    expectedRunning = false
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

    companion object {
        private const val CHANNEL = "com.dailightstudio.echomic/audio"
        private const val EVENT_CHANNEL = "com.dailightstudio.echomic/events"

        init {
            System.loadLibrary("echomic_engine")
        }
    }
}
