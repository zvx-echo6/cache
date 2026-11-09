package com.happylittlellc.cache.car

import android.app.NotificationChannel
import android.app.NotificationManager
import android.annotation.SuppressLint
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.car.app.notification.CarAppExtender
import androidx.car.app.notification.CarPendingIntent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.happylittlellc.cache.R

/**
 * The turn-by-turn notification (quality rule NF-3): ongoing, category navigation, extended for the car. It shows in the car's
 * rail and, when the next maneuver changes, as a heads-up notification (the host hides those while Cache's own guidance is on
 * the screen). Tapping it opens Cache in the car.
 */
class CarNotifications(private val context: Context) {
    private val nm = NotificationManagerCompat.from(context)
    private var lastCue: String? = null

    init {
        val ch = NotificationChannel(CHANNEL, "Turn-by-turn in the car", NotificationManager.IMPORTANCE_HIGH)
        ch.setSound(null, null)
        ch.enableVibration(false)
        nm.createNotificationChannel(ch)
    }

    fun show(t: CarTrip) {
        try {
            post(t)
        } catch (e: Exception) {
            // A notification that cannot be posted never stops guidance.
        }
    }

    @SuppressLint("MissingPermission")
    private fun post(t: CarTrip) {
        val s = t.step ?: return
        if (!nm.areNotificationsEnabled()) return
        val title = CarDistanceText.of(s.distanceM, t.imperial)
        val changed = s.cue != lastCue
        lastCue = s.cue
        val open = CarPendingIntent.getCarApp(
            context, 7301, Intent(Intent.ACTION_VIEW).setComponent(ComponentName(context, CacheCarAppService::class.java)), 0,
        )
        val extender = CarAppExtender.Builder()
            .setContentTitle(title)
            .setContentText(s.cue)
            .setSmallIcon(R.drawable.ic_stat_cache)
            .setLargeIcon(bitmapOf(s.turn))
            .setContentIntent(open)
            .setImportance(if (changed) NotificationManagerCompat.IMPORTANCE_HIGH else NotificationManagerCompat.IMPORTANCE_LOW)
            .build()
        val n = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_cache)
            .setContentTitle(title)
            .setContentText(s.cue)
            .setOngoing(true)
            .setOnlyAlertOnce(!changed)
            .setCategory(NotificationCompat.CATEGORY_NAVIGATION)
            .setSilent(true)
            .extend(extender)
            .build()
        nm.notify(ID, n)
    }

    fun cancel() {
        lastCue = null
        nm.cancel(ID)
    }

    private fun bitmapOf(turn: String): Bitmap {
        val d = CarIcons.maneuver(turn).icon?.loadDrawable(context)
        val b = Bitmap.createBitmap(128, 128, Bitmap.Config.ARGB_8888)
        if (d != null) {
            d.setBounds(0, 0, 128, 128)
            d.draw(Canvas(b))
        }
        return b
    }

    companion object {
        const val CHANNEL = "cache_car_guidance"
        const val ID = 7300
    }
}

/** Plain text for places where the host does not format distances (the notification). */
object CarDistanceText {
    fun of(meters: Double, imperial: Boolean): String {
        val d = CarModels.distance(meters, imperial)
        val v = d.displayDistance
        val n = if (v == Math.floor(v) && d.displayUnit != androidx.car.app.model.Distance.UNIT_MILES_P1 &&
            d.displayUnit != androidx.car.app.model.Distance.UNIT_KILOMETERS_P1) v.toLong().toString() else String.format(java.util.Locale.US, "%.1f", v)
        val unit = when (d.displayUnit) {
            androidx.car.app.model.Distance.UNIT_FEET -> "ft"
            androidx.car.app.model.Distance.UNIT_MILES, androidx.car.app.model.Distance.UNIT_MILES_P1 -> "mi"
            androidx.car.app.model.Distance.UNIT_KILOMETERS, androidx.car.app.model.Distance.UNIT_KILOMETERS_P1 -> "km"
            else -> "m"
        }
        return "$n $unit"
    }
}
