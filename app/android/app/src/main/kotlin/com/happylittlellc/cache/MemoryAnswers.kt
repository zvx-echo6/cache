package com.happylittlellc.cache

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * What the app asks the system on the `co.cache/memory` channel: the free memory, the phone's model, and why the app's process
 * ended the last times (lib/platform/memory.dart, lib/platform/app_log_io.dart).
 *
 * It is answered by the engine itself (car/SharedEngine.kt), with or without a phone screen. It used to be answered by the
 * activity, so a run that the car started with the phone app closed could not read the system's reasons and wrote a
 * "stopped unexpectedly" line for every update or stop of the app. Everything here needs only the application context.
 */
object MemoryAnswers {
    const val CHANNEL = "co.cache/memory"

    fun attach(messenger: BinaryMessenger, context: Context) {
        val app = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "read" -> result.success(memory(app))
                // The log's header: the phone's maker and model.
                "device" -> result.success("${Build.MANUFACTURER} ${Build.MODEL}")
                // The log: why the app's process ended the last times (Android 11 and later).
                "exits" -> result.success(exits(app))
                else -> result.notImplemented()
            }
        }
    }

    fun memory(context: Context): Map<String, Any> {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return emptyMap()
        val info = ActivityManager.MemoryInfo()
        am.getMemoryInfo(info)
        return mapOf("avail" to info.availMem, "total" to info.totalMem, "threshold" to info.threshold, "low" to info.lowMemory)
    }

    fun exits(context: Context): List<Map<String, Any>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return emptyList()
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return emptyList()
        return try {
            am.getHistoricalProcessExitReasons(context.packageName, 0, 8).map { e ->
                val reason = when (e.reason) {
                    android.app.ApplicationExitInfo.REASON_CRASH -> "crash"
                    android.app.ApplicationExitInfo.REASON_CRASH_NATIVE -> "native crash"
                    android.app.ApplicationExitInfo.REASON_ANR -> "not responding"
                    android.app.ApplicationExitInfo.REASON_LOW_MEMORY -> "low memory"
                    android.app.ApplicationExitInfo.REASON_EXIT_SELF -> "closed itself"
                    android.app.ApplicationExitInfo.REASON_SIGNALED -> "stopped by a signal"
                    android.app.ApplicationExitInfo.REASON_USER_REQUESTED -> "stopped by the user"
                    android.app.ApplicationExitInfo.REASON_USER_STOPPED -> "force stopped"
                    android.app.ApplicationExitInfo.REASON_OTHER -> "other"
                    // numbers from the ApplicationExitInfo reference (these two are API 34; the app's compileSdk may predate them)
                    8 -> "permission changed"
                    15 -> "app changed"
                    16 -> "app updated"
                    else -> "reason ${e.reason}"
                }
                mapOf("time" to e.timestamp, "reason" to reason, "code" to e.reason, "description" to (e.description ?: ""), "pss" to e.pss, "rss" to e.rss)
            }
        } catch (e: Exception) {
            emptyList()
        }
    }
}
