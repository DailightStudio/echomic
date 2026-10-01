package com.dailightstudio.echomic

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Foreground service that exists solely to satisfy Android's
 * foregroundServiceType=microphone requirement while the native Oboe engine
 * ([AudioEnginePlugin]/jni_bridge/AudioEngine) is recording+monitoring in the
 * background. It does no audio work itself; AudioEnginePlugin starts this
 * right after nativeStart() succeeds and stops it right after nativeStop().
 */
class EchoMicForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(CONTENT_TITLE)
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

        // ServiceCompat.startForeground() picks the right startForeground()
        // overload per API level (it is the one that takes a foreground
        // service type on API 29+, and follows Android 14's stricter
        // FGS-type rules on API 34+); on pre-29 it falls back to the
        // 2-arg form automatically.
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        )
        return START_STICKY
    }

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_LOW)
                )
            }
        }
    }

    companion object {
        private const val CHANNEL_ID = "echomic_running"
        private const val CHANNEL_NAME = "에코마이크 실행 상태"
        private const val CONTENT_TITLE = "에코마이크 실행 중"
        private const val NOTIFICATION_ID = 42
    }
}
