package com.dailightstudio.echomic

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(AudioEnginePlugin())
    }

    // FlutterActivity forwards both the legacy back button AND predictive
    // back gestures to Dart's NavigationChannel; when Dart has no more
    // routes to pop it calls back here via this Host hook (PlatformPlugin.
    // popSystemNavigator()) before falling back to Activity.finish(). While
    // the native engine is running, intercept that and background the task
    // instead -- finishing would destroy the FlutterEngine, which tears
    // down the mic (AudioEnginePlugin.onDetachedFromEngine -> nativeStop()
    // + stopForegroundService()).
    override fun popSystemNavigator(): Boolean {
        if (nativeIsRunning()) {
            moveTaskToBack(true)
            return true
        }
        return super.popSystemNavigator()
    }

    // Reads AudioEngine's running_ flag directly (ignores `this`; see
    // jni_bridge.cpp) so Back can decide synchronously without round-
    // tripping through the Flutter plugin/method channel.
    private external fun nativeIsRunning(): Boolean

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Needed for the "에코마이크 실행 중" ongoing notification the
        // microphone foreground service posts while recording (see
        // EchoMicForegroundService); the FGS itself still runs without it,
        // Android just won't show the notification banner. Fire-and-forget:
        // no result handling needed, the user can grant it later from
        // system settings.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_POST_NOTIFICATIONS)
        }
    }

    companion object {
        private const val REQUEST_POST_NOTIFICATIONS = 1001

        init {
            System.loadLibrary("echomic_engine")
        }
    }
}
