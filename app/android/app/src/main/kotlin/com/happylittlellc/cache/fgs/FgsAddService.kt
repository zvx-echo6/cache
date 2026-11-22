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
 *
 * It also carries region map downloads (layer jobs, which run in the app's own engine and need only the process kept alive): the
 * service stays up while EITHER a PDF add OR a region download runs. The notification shows the PDF add while it runs, then the
 * region; it stops only when both are done. Dart tells it the region's progress and its end (FgsAddArm.layerProgress, armLayers).
 */
class FgsAddService : Service(), FgsAddEvents {
    private var runner: FgsAddRunner? = null
    private var wake: PowerManager.WakeLock? = null
    private var last: FgsProgress? = null
    private var lastNotifyAt = 0L
    private var over = false
    private var pausing = false

    /** A region download runs (told by Dart), with its latest words. */
    private var layersActive = false
    private var lastLayers: FgsLayerWords? = null

    /** The service is going down: nothing more is done. */
    private var down = false
    private var up = false

    private fun pdfActive() = runner != null && !over

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            FgsAddNotifications.ACTION_PAUSE -> {
                // Pause in the notification: the add stops after the piece it is on and keeps what is done; the notification says
                // Paused at once, and later progress does not put "Adding" back
                if (pdfActive()) {
                    pausing = true
                    notify(FgsAddNotifications.ID_ADDING, FgsAddNotifications.pausing(this, last))
                    runner?.stop("person")
                } else if (layersActive) {
                    // only a region download runs: the app pauses it (it keeps what it fetched); its end, told by Dart, stops the service
                    FgsAddArm.pauseLayers()
                }
                return START_NOT_STICKY
            }
        }
        val wantPdf = intent?.getBooleanExtra(EXTRA_PDF, true) != false
        val wantLayers = intent?.getBooleanExtra(EXTRA_LAYERS, false) == true
        if (up) {
            // already running (for a region, or for a PDF add): a second start adds what is missing
            if (wantLayers && !layersActive) {
                layersActive = true
                lastLayers = FgsAddArm.lastLayers
            }
            if (wantPdf && runner == null) {
                startRun(intent)
                notify(FgsAddNotifications.ID_ADDING, FgsAddNotifications.adding(this, null))
            }
            return START_NOT_STICKY
        }
        layersActive = wantLayers
        lastLayers = if (wantLayers) FgsAddArm.lastLayers else null
        FgsAddNotifications.ensureChannels(this)
        try {
            val first = if (wantPdf) FgsAddNotifications.adding(this, null) else FgsAddNotifications.layers(this, lastLayers)
            ServiceCompat.startForeground(this, FgsAddNotifications.ID_ADDING, first, FGS_TYPE)
        } catch (e: Exception) {
            // not allowed now (started from the background, or the type's permission): nothing is running, the charging run carries on
            Log.w(TAG, "the foreground service could not start", e)
            layersActive = false
            stopSelf()
            return START_NOT_STICKY
        }
        running = true
        instance = this
        up = true
        down = false
        over = !wantPdf
        pausing = false
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG).apply {
            setReferenceCounted(false)
            acquire(WAKE_LOCK_MAX_MS)
        }
        if (wantPdf) startRun(intent)
        return START_NOT_STICKY
    }

    /** Starts the Dart PDF add (the first, or one the person started while only a region download ran). */
    private fun startRun(intent: Intent?) {
        val resume = intent?.getBooleanExtra(FgsAddNotifications.EXTRA_RESUME, false) == true
        val anyway = intent?.getBooleanExtra(FgsAddNotifications.EXTRA_ANYWAY, false) == true
        over = false
        pausing = false
        last = null
        lastNotifyAt = 0L
        runner = runnerFactory(this).also { it.start(resume, anyway, this) }
    }

    private fun showLayers() = notify(FgsAddNotifications.ID_ADDING, FgsAddNotifications.layers(this, lastLayers))

    /** The region download's progress (FgsAddArm): shown when no PDF add is; a region that starts while the service runs joins it. */
    internal fun onLayerProgress(w: FgsLayerWords) {
        if (down) return
        lastLayers = w
        layersActive = true
        if (pdfActive()) return
        val now = SystemClock.elapsedRealtime()
        if (lastNotifyAt != 0L && now - lastNotifyAt < MIN_UPDATE_MS) return
        lastNotifyAt = now
        showLayers()
    }

    /** The last region download ended: the service goes when no PDF add runs either. */
    internal fun onLayersEnded() {
        if (down) return
        layersActive = false
        lastLayers = null
        if (pdfActive()) return
        over = true
        stopForeground()
        runner?.release(0)
        finish()
    }

    override fun onProgress(p: FgsProgress) {
        if (over) return
        last = p
        if (pausing) return
        // at most one update a second (Android also limits them, and each one wakes the system UI)
        val now = SystemClock.elapsedRealtime()
        if (lastNotifyAt != 0L && now - lastNotifyAt < MIN_UPDATE_MS) return
        lastNotifyAt = now
        notify(FgsAddNotifications.ID_ADDING, FgsAddNotifications.adding(this, p))
    }

    override fun onFinished(f: FgsFinish) {
        if (over) return
        over = true
        if (layersActive) {
            // a region download still runs: the service stays up, the PDF add's result is posted, and the ongoing notification is the region's
            FgsAddNotifications.ended(this, f)?.let { notify(FgsAddNotifications.ID_RESULT, it) }
            runner?.release(0)
            runner = null
            pausing = false
            lastNotifyAt = SystemClock.elapsedRealtime()
            showLayers()
            return
        }
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
        if (down) return
        val pdfWas = pdfActive()
        over = true
        if (pdfWas) runner?.stop("timeout")
        // a region download is paused the way the notification's Pause pauses it (it keeps what it fetched)
        if (layersActive) FgsAddArm.pauseLayers()
        stopForeground()
        if (pdfWas) notify(FgsAddNotifications.ID_RESULT, FgsAddNotifications.timedOut(this, last))
        runner?.release(if (pdfWas) ENGINE_GRACE_MS else 0)
        finish()
    }

    private fun stopForeground() = ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)

    private fun finish() {
        wake?.let { if (it.isHeld) it.release() }
        wake = null
        runner = null
        layersActive = false
        lastLayers = null
        down = true
        up = false
        running = false
        if (instance === this) instance = null
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
        layersActive = false
        down = true
        up = false
        running = false
        if (instance === this) instance = null
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

        /** The service is up for a PDF add, and for a region download. */
        val pdfRunning: Boolean get() = instance?.pdfActive() == true
        val layersRunning: Boolean get() = instance?.layersActive == true

        @Volatile
        private var instance: FgsAddService? = null

        /** Start extras: [EXTRA_PDF] (default true) starts the PDF add; [EXTRA_LAYERS] says a region download runs. */
        const val EXTRA_PDF = "pdf"
        const val EXTRA_LAYERS = "layers"

        fun layerProgress(w: FgsLayerWords) {
            instance?.onLayerProgress(w)
        }

        fun layersEnded() {
            instance?.onLayersEnded()
        }

        fun startIntent(context: Context, pdf: Boolean = true, layers: Boolean = false): Intent =
            Intent(context, FgsAddService::class.java).setAction(FgsAddNotifications.ACTION_START).apply {
                if (!pdf) putExtra(EXTRA_PDF, false)
                if (layers) putExtra(EXTRA_LAYERS, true)
            }
    }
}
