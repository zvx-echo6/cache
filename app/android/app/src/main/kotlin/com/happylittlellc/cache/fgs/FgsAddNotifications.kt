package com.happylittlellc.cache.fgs

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.happylittlellc.cache.R

/**
 * The notifications of the foreground service that adds PDFs in the background (design: renders/fgs/design.md and wording.md,
 * branch design/fgs-background-add). Both channels are SILENT (low importance, no sound, no vibration). The lock screen shows a
 * private public version: no file names and no library names, only that PDFs are being added in the background.
 *
 * Every string here is a DRAFT from wording.md, not yet approved by the owner; the ones that reuse the app's existing Add PDF
 * words (the error words, "Paused by you", "Resume", "Resume anyway", "Pause") are the same words.
 */
object FgsAddNotifications {
    const val CHANNEL_ADDING = "fgs-add-adding"
    const val CHANNEL_RESULTS = "fgs-add-results"
    const val ID_ADDING = 7410
    const val ID_RESULT = 7411

    // WORDING QUESTION (owner): draft, not yet approved
    const val CHANNEL_ADDING_NAME = "Adding PDFs"
    // WORDING QUESTION (owner): draft, not yet approved
    const val CHANNEL_ADDING_DESCRIPTION = "Shown while Cache adds PDFs in the background"
    // WORDING QUESTION (owner): draft, not yet approved
    const val CHANNEL_RESULTS_NAME = "PDFs added"
    // WORDING QUESTION (owner): draft, not yet approved
    const val CHANNEL_RESULTS_DESCRIPTION = "Where adding PDFs ended, paused or failed"

    // The lock screen's private version. WORDING QUESTION (owner): draft, not yet approved
    const val PUBLIC_ADDING_TITLE = "Adding PDFs"
    const val PUBLIC_ADDING_TEXT = "In the background"
    const val PUBLIC_DONE_TITLE = "PDFs added"
    const val PUBLIC_DONE_TEXT = "Open Cache to see them"
    // For a run that paused or failed ("PDFs added" would be wrong there); a draft of mine, not in wording.md. WORDING QUESTION (owner): draft, not yet approved
    const val PUBLIC_STOPPED_TITLE = "Adding PDFs"

    // WORDING QUESTION (owner): draft, not yet approved
    const val LIMIT_TEXT = "Android limits background work. It carries on while charging, or open Cache."
    // WORDING QUESTION (owner): draft, not yet approved
    const val ADDING_SEARCH_INDEX = "Adding to search index"

    const val ACTION_PAUSE = "co.cache.fgs.PAUSE"
    const val ACTION_START = "co.cache.fgs.START"
    const val EXTRA_RESUME = "resume"
    const val EXTRA_ANYWAY = "anyway"

    fun ensureChannels(context: Context) {
        val nm = NotificationManagerCompat.from(context)
        for ((id, name, desc) in listOf(
            Triple(CHANNEL_ADDING, CHANNEL_ADDING_NAME, CHANNEL_ADDING_DESCRIPTION),
            Triple(CHANNEL_RESULTS, CHANNEL_RESULTS_NAME, CHANNEL_RESULTS_DESCRIPTION),
        )) {
            val ch = NotificationChannel(id, name, NotificationManager.IMPORTANCE_LOW)
            ch.description = desc
            ch.setSound(null, null)
            ch.enableVibration(false)
            ch.setShowBadge(false)
            ch.lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            nm.createNotificationChannel(ch)
        }
    }

    // Opens Cache. LATER ITEM (owner OK for 52): a deep link to the Adding a PDF page.
    private fun open(context: Context): PendingIntent? {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return null
        return PendingIntent.getActivity(context, 7412, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    private fun toService(context: Context, requestCode: Int, action: String, anyway: Boolean = false): PendingIntent {
        val i = Intent(context, FgsAddService::class.java).setAction(action)
        if (action == ACTION_START) {
            i.putExtra(EXTRA_RESUME, true)
            i.putExtra(EXTRA_ANYWAY, anyway)
            // a notification action may start a foreground service (an allowed case since Android 12)
            return PendingIntent.getForegroundService(context, requestCode, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
        return PendingIntent.getService(context, requestCode, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    private fun base(context: Context, channel: String, title: String, text: String?): NotificationCompat.Builder =
        NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_stat_cache)
            .setContentTitle(title)
            .setContentText(text)
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(true)
            .setContentIntent(open(context))
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)

    private fun publicVersion(context: Context, channel: String, title: String, text: String): Notification =
        NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_stat_cache)
            .setContentTitle(title)
            .setContentText(text)
            .setSilent(true)
            .build()

    /** The ongoing notification while adding. [p] null: nothing is known yet (indeterminate). */
    fun adding(context: Context, p: FgsProgress?): Notification {
        val several = p != null && p.total > 1
        val title = if (several) "Adding PDFs to ${p!!.library}" else "Adding a PDF"
        val text = when {
            p == null -> null
            several -> "${p.done} of ${p.total} PDFs · ${p.current}"
            else -> p.current
        }
        val b = base(context, CHANNEL_ADDING, title, text)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setPublicVersion(publicVersion(context, CHANNEL_ADDING, PUBLIC_ADDING_TITLE, PUBLIC_ADDING_TEXT))
            .addAction(0, "Pause", toService(context, 7413, ACTION_PAUSE))
        if (p?.left != null) b.setSubText(p.left)
        if (p?.bar != null) b.setProgress(1000, (p.bar * 1000).toInt().coerceIn(0, 1000), false) else b.setProgress(0, 0, true)
        if (p?.more != null) b.setStyle(NotificationCompat.BigTextStyle().bigText("$text\n${p.more}"))
        return b.build()
    }

    /** The notification that ends a run (not ongoing: the person can swipe it away); null when nothing was started. */
    fun ended(context: Context, f: FgsFinish): Notification? {
        val title: String
        val text: String
        var action: Triple<String, Int, Boolean>? = null
        var publicTitle = PUBLIC_DONE_TITLE
        var publicText = PUBLIC_DONE_TEXT
        when (f.kind) {
            "added" -> {
                title = if (f.added > 1) "Added ${f.added} PDFs to ${f.library}" else "Added to ${f.library}"
                text = ADDING_SEARCH_INDEX
            }
            "failed" -> {
                publicTitle = PUBLIC_STOPPED_TITLE
                if (f.failed == 1 && f.failedTitle != null) {
                    title = f.failedTitle
                    text = listOfNotNull(f.failedName, f.failedBody).joinToString(" · ")
                } else if (f.added > 0) {
                    title = "Added ${f.added} of ${f.total} PDFs to ${f.library}"
                    text = "${f.failed} could not be added · tap to see"
                } else {
                    title = "${f.failed} PDFs could not be added"
                    text = "Tap to see them"
                }
            }
            "paused" -> {
                publicTitle = PUBLIC_STOPPED_TITLE
                title = "Paused · ${f.done} of ${f.total} PDFs"
                text = when (f.why) {
                    "person" -> "Paused by you"
                    "battery" -> if (f.battery == null) "Battery low · plug in to continue" else "Battery low (${f.battery}%) · plug in to continue"
                    "heat" -> if (f.warm) "Device is warm" else "Keeping the device cool"
                    else -> LIMIT_TEXT
                }
                action = when (f.why) {
                    "person" -> Triple("Resume", 7414, false)
                    "battery" -> Triple("Resume anyway", 7415, true)
                    else -> null
                }
            }
            else -> return null
        }
        val b = base(context, CHANNEL_RESULTS, title, text)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setPublicVersion(publicVersion(context, CHANNEL_RESULTS, publicTitle, publicText))
        if (action != null) b.addAction(0, action.first, toService(context, action.second, ACTION_START, action.third))
        return b.build()
    }

    /** Android's time limit (API 35): paused with what was done so far, the limit's words, no action (it carries on while charging). */
    fun timedOut(context: Context, last: FgsProgress?): Notification =
        ended(context, FgsFinish("paused", "timeout", last?.done ?: 0, last?.total ?: 0, 0, 0, null, false, last?.library ?: "Bookshelves", null, null, null))!!
}
