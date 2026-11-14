package com.happylittlellc.cache.fgs

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * TEST APK ONLY (declared in src/testhook/AndroidManifest.xml, merged only with -PcacheTestApk=true): lets a device round press the
 * notification's Pause, Resume and Resume anyway with `adb shell am broadcast`, without opening the shade. It sends the service the
 * very intent the notification's button sends. The class is compiled into every build but declared in none but the test one, so
 * nothing in a release build can reach it (FgsAddTest asserts that the release manifest has no such receiver).
 *
 *   adb shell am broadcast -a co.cache.fgs.test.PAUSE -n com.happylittlellc.cache.test/com.happylittlellc.cache.fgs.FgsAddTestHook
 */
class FgsAddTestHook : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Log.i(TAG, "test hook: ${intent.action}")
        when (intent.action) {
            ACTION_PAUSE -> context.startService(Intent(context, FgsAddService::class.java).setAction(FgsAddNotifications.ACTION_PAUSE))
            ACTION_RESUME, ACTION_RESUME_ANYWAY -> try {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, FgsAddService::class.java)
                        .setAction(FgsAddNotifications.ACTION_START)
                        .putExtra(FgsAddNotifications.EXTRA_RESUME, true)
                        .putExtra(FgsAddNotifications.EXTRA_ANYWAY, intent.action == ACTION_RESUME_ANYWAY),
                )
            } catch (e: Exception) {
                // Android may refuse a foreground start from a broadcast (the shade's own button is exempt); the round says so
                Log.w(TAG, "the service could not be started from the test hook", e)
            }
        }
    }

    companion object {
        private const val TAG = "FgsAddTestHook"
        const val ACTION_PAUSE = "co.cache.fgs.test.PAUSE"
        const val ACTION_RESUME = "co.cache.fgs.test.RESUME"
        const val ACTION_RESUME_ANYWAY = "co.cache.fgs.test.RESUME_ANYWAY"
    }
}
