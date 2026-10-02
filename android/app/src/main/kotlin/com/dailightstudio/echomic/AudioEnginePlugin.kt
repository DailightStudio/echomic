package com.dailightstudio.echomic

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
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

    // Pushes a 'route' event whenever an output device comes or goes so the
    // UI can re-evaluate speaker/wired/bluetooth hints without polling.
    private var deviceCallback: AudioDeviceCallback? = null

    // Why the engine last stopped on its own ("unplug"); null after a user
    // stop. Attached to the running:false event so the UI can say what happened.
    private var stopReason: String? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
                startPolling()
                registerDeviceCallback()
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
                stopPolling()
                unregisterDeviceCallback()
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        stopPolling()
        unregisterDeviceCallback()
        eventSink = null
        nativeStop()
        stopForegroundService()
        unregisterNoisyReceiver()
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "start" -> {
                stopReason = null
                val ok = nativeStart()
                expectedRunning = ok
                if (ok) {
                    startForegroundService()
                    registerNoisyReceiver()
                }
                result.success(ok)
            }
            "stop" -> {
                nativeStop()
                expectedRunning = false
                stopReason = null
                stopForegroundService()
                unregisterNoisyReceiver()
                result.success(null)
            }
            "routeInfo" -> result.success(routeInfo())
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
                    sink.success(stateStoppedEvent())
                    expectedRunning = false
                    // Native died on its own (e.g. a failed input read/
                    // reconnect) without going through stop(): the FGS
                    // notification would otherwise outlive the engine.
                    stopForegroundService()
                    unregisterNoisyReceiver()
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

    // --- Foreground-service lifecycle (mirrors native start/stop 1:1) ---
    private fun startForegroundService() {
        val intent = Intent(appContext, EchoMicForegroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            appContext.startForegroundService(intent)
        } else {
            appContext.startService(intent)
        }
    }

    private fun stopForegroundService() {
        appContext.stopService(Intent(appContext, EchoMicForegroundService::class.java))
    }

    // --- Stop before the route falls back to the speaker (fix: unplug-> howl) ---
    private fun registerNoisyReceiver() {
        if (noisyReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                stopReason = "unplug"
                nativeStop()
                expectedRunning = false
                stopForegroundService()
                unregisterNoisyReceiver()
                eventSink?.success(stateStoppedEvent())
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

    private fun stateStoppedEvent(): Map<String, Any> {
        val event = mutableMapOf<String, Any>("type" to "state", "running" to false)
        stopReason?.let { event["reason"] = it }
        return event
    }

    // --- Output route (speaker / wired / bluetooth) + latency for the UI ---
    private fun routeInfo(): Map<String, Any> {
        val am = appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        var output = "speaker"
        // Wired wins over BT (that is how the platform routes when both are
        // attached); anything attached beats the built-in speaker.
        var hasWired = false
        var hasBt = false
        for (d in am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
            when (d.type) {
                AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_USB_DEVICE -> hasWired = true
                AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> hasBt = true
                else -> if (Build.VERSION.SDK_INT >= 33 &&
                    (d.type == AudioDeviceInfo.TYPE_BLE_HEADSET || d.type == AudioDeviceInfo.TYPE_BLE_SPEAKER)) hasBt = true
            }
        }
        if (hasWired) output = "wired" else if (hasBt) output = "bluetooth"
        val info = mutableMapOf<String, Any>("output" to output)
        val latency = nativeGetLatencyMs()
        if (latency >= 0) info["latencyMs"] = latency
        return info
    }

    private fun registerDeviceCallback() {
        if (deviceCallback != null) return
        val am = appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val cb = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>?) = pushRoute()
            override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>?) = pushRoute()
            private fun pushRoute() {
                val sink = eventSink ?: return
                val event = mutableMapOf<String, Any>("type" to "route")
                event.putAll(routeInfo())
                sink.success(event)
            }
        }
        am.registerAudioDeviceCallback(cb, android.os.Handler(android.os.Looper.getMainLooper()))
        deviceCallback = cb
    }

    private fun unregisterDeviceCallback() {
        deviceCallback?.let {
            (appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager).unregisterAudioDeviceCallback(it)
            deviceCallback = null
        }
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
    private external fun nativeGetLatencyMs(): Double
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
