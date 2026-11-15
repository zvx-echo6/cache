package com.happylittlellc.cache

import android.app.PendingIntent
import android.content.Context
import android.content.Intent

/**
 * What a tap on one of the phone's guidance notifications opens: Cache's activity, which tells Dart to show the Maps tab
 * (lib/nav/open_maps.dart reads it on the channel `co.cache/open`). Used by the turn-by-turn notification as the phone shows it
 * (car/CarNotifications.kt; the car keeps its own tap, which opens Cache in the car) and by "Cache is on the car screen"
 * (car/CarLocationService.kt).
 */
object OpenMaps {
    const val ACTION = "com.happylittlellc.cache.OPEN_MAPS"
    const val EXTRA = "cache_open"
    const val MAPS = "maps"

    /** The activity, brought to the front (a running one gets it in onNewIntent), asked for the Maps tab. */
    fun intent(context: Context): Intent = Intent(context, MainActivity::class.java)
        .setAction(ACTION)
        .putExtra(EXTRA, MAPS)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)

    /** The notification's tap. [requestCode] keeps each notification's own. */
    fun pending(context: Context, requestCode: Int): PendingIntent =
        PendingIntent.getActivity(context, requestCode, intent(context), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    /**
     * Whether [i] asks for the Maps tab. An activity brought back from the Recents list repeats the intent it was first started
     * with; that is not a new tap.
     */
    fun wants(i: Intent?): Boolean {
        if (i == null || i.getStringExtra(EXTRA) != MAPS) return false
        return (i.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) == 0
    }
}
