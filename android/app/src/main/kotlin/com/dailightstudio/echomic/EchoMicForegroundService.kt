package com.dailightstudio.echomic

import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Foreground service that exists solely to satisfy Android's
 * foregroundServiceType=microphone requirement while the native Oboe engine
 * ([AudioEnginePlugin]/jni_bridge/AudioEngine) is recording+monitoring in the
 * background. It does no audio work itself; AudioEnginePlugin starts it right
 * after nativeStart() succeeds and stops it right after nativeStop(), always
 * through [start]/[stop].
 *
 * Everything here runs on the main thread (plugin method calls and service
 * callbacks both do), so the companion state needs no locking.
 */
class EchoMicForegroundService : Service() {

    private var inForeground = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        NotificationManagerCompat.from(this).createNotificationChannel(
            NotificationChannelCompat.Builder(CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_LOW)
                .setName(CHANNEL_NAME)
                .build()
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // "정지" on the notification: the plugin stops the engine, which
            // calls back into stop() and ends this service.
            onStopFromNotification?.invoke() ?: stopSelf()
            return START_NOT_STICKY
        }

        // ServiceCompat.startForeground() picks the right startForeground()
        // overload per API level (it is the one that takes a foreground
        // service type on API 29+, and follows Android 14's stricter
        // FGS-type rules on API 34+); on pre-29 it falls back to the
        // 2-arg form automatically.
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            buildNotification(),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        )
        inForeground = true
        if (stopPending) {
            // Stop arrived before we got here. Stopping earlier would have
            // crashed the app ("startForegroundService() did not then call
            // startForeground()"), so it waited until now.
            finish()
        }
        // Not sticky: a system restart would come from the background, where
        // Android 14 refuses a microphone FGS, and the engine would not be running.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    private fun finish() {
        stopPending = false
        requested = false
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun buildNotification() = NotificationCompat.Builder(this, CHANNEL_ID)
        .setContentTitle(CONTENT_TITLE)
        .setContentText(CONTENT_TEXT)
        .setSmallIcon(R.drawable.ic_stat_mic)
        .setOngoing(true)
        .setPriority(NotificationCompat.PRIORITY_LOW)
        .setContentIntent(
            packageManager.getLaunchIntentForPackage(packageName)?.let {
                PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE)
            }
        )
        .addAction(
            R.drawable.ic_stat_mic,
            ACTION_STOP_LABEL,
            PendingIntent.getService(
                this,
                1,
                Intent(this, EchoMicForegroundService::class.java).setAction(ACTION_STOP),
                PendingIntent.FLAG_IMMUTABLE
            )
        )
        .build()

    companion object {
        private const val CHANNEL_ID = "echomic_running"
        private const val CHANNEL_NAME = "에코마이크 실행 상태"
        private const val CONTENT_TITLE = "에코마이크 실행 중"
        private const val CONTENT_TEXT = "눌러서 앱 열기"
        private const val ACTION_STOP_LABEL = "정지"
        private const val ACTION_STOP = "com.dailightstudio.echomic.STOP"
        private const val NOTIFICATION_ID = 42

        private var instance: EchoMicForegroundService? = null
        private var requested = false   // start() went out and no stop has completed
        private var stopPending = false // stop() came before startForeground()

        /** Set by the plugin: stop the engine when "정지" is tapped in the shade. */
        var onStopFromNotification: (() -> Unit)? = null

        /**
         * Throws when Android refuses (app already in the background:
         * ForegroundServiceStartNotAllowedException on 12+, SecurityException
         * for the microphone type on 14+). The caller must stop the engine then.
         */
        fun start(context: Context) {
            stopPending = false
            ContextCompat.startForegroundService(
                context, Intent(context, EchoMicForegroundService::class.java)
            )
            requested = true
        }

        fun stop() {
            if (!requested) return
            val service = instance
            if (service != null && service.inForeground) service.finish() else stopPending = true
        }
    }
}
