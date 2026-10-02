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
    private var lastStartId = 0

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
        // A Start right after a stop can land on this same instance before it
        // is destroyed (Android reuses it; seen as lastStartId=2 in dumpsys),
        // so re-attach on every command, not only in onCreate.
        instance = this
        lastStartId = startId
        if (intent?.action == ACTION_STOP) {
            // "정지" on the notification: the plugin stops the engine, which
            // calls back into stop() and ends this service.
            onStopFromNotification?.invoke() ?: stopSelfResult(startId)
            return START_NOT_STICKY
        }

        // ServiceCompat.startForeground() picks the right startForeground()
        // overload per API level (it is the one that takes a foreground
        // service type on API 29+, and follows Android 14's stricter
        // FGS-type rules on API 34+); on pre-29 it falls back to the
        // 2-arg form automatically.
        try {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                buildNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            )
        } catch (e: RuntimeException) {
            // Android 14+ checks the microphone type here, not at
            // startForegroundService(): the app left the foreground between
            // the plugin's foreground check and now (milliseconds). There is
            // no clean way out -- a service started with
            // startForegroundService() that stops without startForeground()
            // is crashed by the system (ActiveServices fgRequired) -- so the
            // point is only to release the mic before that happens.
            android.util.Log.w("EchoMicFGS", "startForeground refused", e)
            requested = false
            stopPending = false
            onForegroundRefused?.invoke()
            stopSelf()
            return START_NOT_STICKY
        }
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
        // Not foreground any more, so a stop() from here on is held as
        // pending until the next start command (on this instance or a new one)
        // instead of acting on this one.
        inForeground = false
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        // Only if no newer start arrived meanwhile: plain stopSelf() would
        // also cancel a Start that is already queued for this instance.
        stopSelfResult(lastStartId)
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

        /** Set by the plugin for a session: "정지" tapped in the shade. */
        var onStopFromNotification: (() -> Unit)? = null

        /** Set by the plugin for a session: Android refused startForeground(). */
        var onForegroundRefused: (() -> Unit)? = null

        /**
         * Throws ForegroundServiceStartNotAllowedException (12+) when the app
         * is already in the background; the caller must stop the engine then.
         * A later refusal inside startForeground() (14+, microphone type)
         * arrives through [onForegroundRefused] instead.
         */
        fun start(context: Context) {
            ContextCompat.startForegroundService(
                context, Intent(context, EchoMicForegroundService::class.java)
            )
            // Only once the request is out: if it threw, an earlier instance
            // still waiting to go foreground must keep its pending stop.
            stopPending = false
            requested = true
        }

        fun stop() {
            if (!requested) return
            val service = instance
            if (service != null && service.inForeground) service.finish() else stopPending = true
        }
    }
}
