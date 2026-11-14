package com.happylittlellc.cache.fgs

import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat

/**
 * The foreground service that keeps adding PDFs after the person leaves Cache (design: renders/fgs/design.md). A background add
 * is about ten times slower than one in front and Android freezes a cached app, so a foreground service with a notification
 * carries it. It is started while Cache is still in front, as the person leaves (FgsAddArm), since Android 12 refuses a start
 * from the background.
 *
 * It runs the same Dart add as the WorkManager charging run (DartFgsAddRunner), holds a partial wake lock while it runs, and
 * ends by itself when nothing is left, on Pause, and at Android 15's time limit ([onTimeout]).
 */
class FgsAddService : Service(), FgsAddEvents {
    private var runner: FgsAddRunner? = null
    private var wake: PowerManager.WakeLock? = null
    private var last: FgsProgress? = null
    private var lastNotifyAt = 0L
    private var over = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            FgsAddNotifications.ACTION_PAUSE -> {
                // Pause in the notification: the add stops after its step and keeps what is done
                runner?.stop("person")
                return START_NOT_STICKY
            }
        }
        if (runner != null) return START_NOT_STICKY
        val resume = intent?.getBooleanExtra(FgsAddNotifications.EXTRA_RESUME, false) == true
        val anyway = intent?.getBooleanExtra(FgsAddNotifications.EXTRA_ANYWAY, false) == true
        FgsAddNotifications.ensureChannels(this)
        try {
            ServiceCompat.startForeground(this, FgsAddNotifications.ID_ADDING, FgsAddNotifications.adding(this, null), FGS_TYPE)
        } catch (e: Exception) {
            // not allowed now (started from the background, or the type's permission): nothing is running, the charging run carries on
            Log.w(TAG, "the foreground service could not start", e)
            stopSelf()
            return START_NOT_STICKY
        }
        running = true
        over = false
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG).apply {
            setReferenceCounted(false)
            acquire(WAKE_LOCK_MAX_MS)
        }
        runner = runnerFactory(this).also { it.start(resume, anyway, this) }
        return START_NOT_STICKY
    }

    override fun onProgress(p: FgsProgress) {
        if (over) return
        last = p
        // at most one update a second (Android also limits them, and each one wakes the system UI)
        val now = SystemClock.elapsedRealtime()
        if (lastNotifyAt != 0L && now - lastNotifyAt < MIN_UPDATE_MS) return
        lastNotifyAt = now
        notify(FgsAddNotifications.ID_ADDING, FgsAddNotifications.adding(this, p))
    }

    override fun onFinished(f: FgsFinish) {
        if (over) return
        over = true
        stopForeground()
        FgsAddNotifications.ended(this, f)?.let { notify(FgsAddNotifications.ID_RESULT, it) }
        runner?.release(0)
        finish()
    }

    /**
     * Android 15: the dataSync limit (6 hours in 24) is reached. The add is asked to pause the way Pause pauses it (the core keeps
     * what is done; a PDF step in flight finishes in the engine, which is kept a little longer to save), the service stops at
     * once (it has a few seconds), and the charging run, queued by the add, picks up what is left.
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        if (over) return
        over = true
        runner?.stop("timeout")
        stopForeground()
        notify(FgsAddNotifications.ID_RESULT, FgsAddNotifications.timedOut(this, last))
        runner?.release(ENGINE_GRACE_MS)
        finish()
    }

    private fun stopForeground() = ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)

    private fun finish() {
        wake?.let { if (it.isHeld) it.release() }
        wake = null
        runner = null
        running = false
        stopSelf()
    }

    @Suppress("MissingPermission")
    private fun notify(id: Int, n: Notification) {
        try {
            val nm = NotificationManagerCompat.from(this)
            // without the permission (Android 13) the system hides it; the service still runs and the app says it on the next open
            if (nm.areNotificationsEnabled()) nm.notify(id, n)
        } catch (e: Exception) {
            Log.w(TAG, "a notification could not be posted", e)
        }
    }

    override fun onDestroy() {
        wake?.let { if (it.isHeld) it.release() }
        wake = null
        runner?.release(0)
        runner = null
        running = false
        super.onDestroy()
    }

    companion object {
        private const val TAG = "FgsAddService"

        /**
         * THE ONE SWITCH: the service's foreground type. dataSync (the documented list includes local file processing, import and
         * export). If Play refuses dataSync, the fallback is SPECIAL_USE: change this constant, the manifest's
         * foregroundServiceType and its permission (FOREGROUND_SERVICE_SPECIAL_USE), and add the PROPERTY_SPECIAL_USE_FGS_SUBTYPE
         * property; nothing else.
         */
        const val FGS_TYPE = ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC

        const val WAKE_LOCK_TAG = "cache:fgs-add"

        /** A safety end for the wake lock: past Android 15's 6 hours. */
        const val WAKE_LOCK_MAX_MS = 7L * 60 * 60 * 1000
        const val MIN_UPDATE_MS = 1000L

        /** After a time limit the engine lives this long, to save what it was doing. */
        const val ENGINE_GRACE_MS = 20_000L

        /** The runner the service makes (tests give a stand-in). */
        @Volatile
        var runnerFactory: (Context) -> FgsAddRunner = { DartFgsAddRunner(it) }

        @Volatile
        var running = false
            private set

        fun startIntent(context: Context): Intent = Intent(context, FgsAddService::class.java).setAction(FgsAddNotifications.ACTION_START)
    }
}
