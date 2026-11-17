package com.happylittlellc.cache.fgs

import android.app.Activity
import android.content.Context
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Starts the add service as the person LEAVES Cache with adds pending: since Android 12 a foreground service cannot be started
 * from the background, so it is started here, while Cache is still in front or just leaving it.
 *
 * Whether adds are pending is decided in Dart (lib/background/fgs_add.dart: not paused, not waiting for charging, battery above
 * the low threshold) and told here on `co.cache/fgs_add` (`arm`), whenever it changes. Nothing is started when it is not armed.
 *
 * What counts as leaving (Pixel check, 2026-11-14):
 * - [Leave.HINT] (`onUserLeaveHint`: Home, and the app switcher on some phones) and Back at the root. But the hint also comes when
 *   the app itself starts an activity (the file picker, a permission prompt): MainActivity calls [noteInternalLaunch] first, and a
 *   hint right after it is not a leave. So are the pause and stop that follow, until the app is resumed.
 * - [Leave.PAUSED]: the app switcher on a phone that never calls the hint: the activity is paused and does not get its window
 *   focus back soon (MainActivity checks after a moment).
 * - [Leave.STOP]: the activity is no longer visible.
 * When the service is started the app is told (`left` on the same channel) so it hands its work off now: Cache's own lifecycle
 * (the Dart side's "hidden") does not come on every one of these.
 */
object FgsAddArm {
    const val CHANNEL = "co.cache/fgs_add"

    /** A leave hint within this long of the app's own launch is that launch's own. */
    const val OWN_LAUNCH_HINT_MS = 3_000L

    enum class Leave { HINT, PAUSED, STOP }

    @Volatile
    var armed = false

    /** A region map download runs (told by Dart as `armLayers`): leaving starts the service for it, with no PDF run. */
    @Volatile
    var armedLayers = false
        private set

    /** The latest words of the region download (`layerProgress`), for a service that starts after they were said. */
    @Volatile
    var lastLayers: FgsLayerWords? = null
        private set

    /** Calls the app on the channel (`layerPause`: the notification's Pause for region downloads); the channel's, or a stand-in in tests. */
    @Volatile
    var tellLayers: (String) -> Unit = {}

    /** The last region download ended (or began): arms or disarms, and a disarm lets the service go when no PDF add runs. */
    fun armLayers(on: Boolean) {
        armedLayers = on
        if (!on) {
            lastLayers = null
            FgsAddService.layersEnded()
        }
    }

    /** The region download's words: kept, and shown by the service when it runs. */
    fun layerProgress(w: FgsLayerWords) {
        lastLayers = w
        FgsAddService.layerProgress(w)
    }

    /** The notification's Pause, for the region downloads: the app pauses them. */
    fun pauseLayers() = tellLayers("layerPause")

    /** Tells the Dart side the person left (`left`); the channel's, or a stand-in in tests. */
    @Volatile
    var tellApp: () -> Unit = {}

    private var internalLaunch = false
    private var internalAt = 0L

    /** The app starts an activity of another app (a picker, a prompt): the leave that follows is its own. */
    fun noteInternalLaunch(now: Long = SystemClock.elapsedRealtime()) {
        internalLaunch = true
        internalAt = now
    }

    /** The app is back in front (onResume): its own launch is over. */
    fun resumed() {
        internalLaunch = false
    }

    fun reset() {
        armed = false
        armedLayers = false
        lastLayers = null
        tellLayers = {}
        internalLaunch = false
        internalAt = 0L
        tellApp = {}
    }

    /**
     * The person is leaving [activity]: start the service when armed, and tell the app. Returns whether a start was asked for.
     */
    fun onLeave(activity: Activity, source: Leave = Leave.HINT, now: Long = SystemClock.elapsedRealtime()): Boolean {
        // said every time, so a device round can see which callbacks arrive (Recents on the Pixel) and why one did not start it
        Log.i("FgsAddArm", "leave: $source armed=$armed running=${FgsAddService.running} changingConfig=${activity.isChangingConfigurations} internal=$internalLaunch")
        // a PDF add needs a start when armed and no PDF run goes; a region download when armed and the service is not up for it:
        // the service stays up for either, and a second start adds the other to the one that runs
        val wantPdf = armed && !FgsAddService.pdfRunning
        val wantLayers = armedLayers && !FgsAddService.layersRunning
        if (!(wantPdf || wantLayers) || activity.isChangingConfigurations) return false
        if (internalLaunch) {
            // the hint the launch itself makes, and the pause and stop while the picker is up: not leaves. A hint long after the launch is the person's.
            val own = source != Leave.HINT || now - internalAt < OWN_LAUNCH_HINT_MS
            if (own) return false
            internalLaunch = false
        }
        return try {
            ContextCompat.startForegroundService(activity, FgsAddService.startIntent(activity, pdf = armed, layers = armedLayers))
            tellApp()
            true
        } catch (e: Exception) {
            Log.w("FgsAddArm", "the add service could not be started", e)
            false
        }
    }

    fun attach(context: Context, messenger: BinaryMessenger) {
        val channel = MethodChannel(messenger, CHANNEL)
        tellApp = { channel.invokeMethod("left", null) }
        tellLayers = { channel.invokeMethod(it, null) }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "arm" -> {
                    armed = call.argument<Boolean>("on") == true
                    result.success(null)
                }
                "armLayers" -> {
                    armLayers(call.argument<Boolean>("on") == true)
                    result.success(null)
                }
                "layerProgress" -> {
                    layerProgress(FgsLayerWords.from(call.arguments as Map<*, *>))
                    result.success(null)
                }
                // Android 13 and later: the notification is hidden without this; the service still runs
                "notificationsAllowed" -> result.success(NotificationManagerCompat.from(context).areNotificationsEnabled())
                else -> result.notImplemented()
            }
        }
    }

    fun detach(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(null)
        tellApp = {}
        tellLayers = {}
    }
}
