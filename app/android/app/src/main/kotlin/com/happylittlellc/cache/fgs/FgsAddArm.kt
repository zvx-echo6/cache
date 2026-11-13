package com.happylittlellc.cache.fgs

import android.app.Activity
import android.content.Context
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Starts the add service as the person LEAVES Cache (Home, recents, or Back at the root) with adds pending: since Android 12 a
 * foreground service cannot be started from the background, so it is started here, while Cache is still in front.
 *
 * Whether adds are pending is decided in Dart (lib/background/fgs_add.dart: not paused, not waiting for charging, battery above
 * the low threshold) and told here on `co.cache/fgs_add` (`arm`), whenever it changes. Nothing is started when it is not armed.
 */
object FgsAddArm {
    const val CHANNEL = "co.cache/fgs_add"

    @Volatile
    var armed = false

    /** The person is leaving [activity]: start the service when armed. Returns whether a start was asked for. */
    fun onLeave(activity: Activity): Boolean {
        if (!armed || activity.isChangingConfigurations || FgsAddService.running) return false
        return try {
            ContextCompat.startForegroundService(activity, FgsAddService.startIntent(activity))
            true
        } catch (e: Exception) {
            Log.w("FgsAddArm", "the add service could not be started", e)
            false
        }
    }

    fun attach(context: Context, messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "arm" -> {
                    armed = call.argument<Boolean>("on") == true
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
    }
}
