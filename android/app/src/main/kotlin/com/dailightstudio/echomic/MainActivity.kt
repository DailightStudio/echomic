package com.dailightstudio.echomic

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

    companion object {
        init {
            System.loadLibrary("echomic_engine")
        }
    }
}
