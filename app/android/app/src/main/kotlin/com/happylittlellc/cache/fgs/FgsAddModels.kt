package com.happylittlellc.cache.fgs

/**
 * What the Dart side of the foreground service's add says (lib/background/fgs_add.dart, background_dispatcher.dart) on the
 * `co.cache/fgs_add_run` channel.
 */

/** Progress while PDFs are added: "[done] of [total] PDFs · [current]". [bar] is 0..1, or null (indeterminate) before the first estimate. */
data class FgsProgress(
    val done: Int,
    val total: Int,
    val current: String,
    val bar: Double?,
    val library: String,
    val left: String?,
    val more: String?,
) {
    companion object {
        fun from(m: Map<*, *>) = FgsProgress(
            done = (m["done"] as? Number)?.toInt() ?: 0,
            total = (m["total"] as? Number)?.toInt() ?: 0,
            current = m["current"] as? String ?: "",
            bar = (m["bar"] as? Number)?.toDouble(),
            library = m["library"] as? String ?: "Bookshelves",
            left = m["left"] as? String,
            more = m["more"] as? String,
        )
    }
}

/**
 * How a run ended. [kind]: "added" (all added), "failed" (some PDF could not be added), "paused" (it stopped with PDFs left:
 * Pause, a low battery, heat, Android's time limit) or "none" (nothing was started: no notification). [why] is the reason a
 * paused run stopped: "person", "battery", "heat", "timeout" or "time".
 */
data class FgsFinish(
    val kind: String,
    val why: String?,
    val done: Int,
    val total: Int,
    val added: Int,
    val failed: Int,
    val battery: Int?,
    val warm: Boolean,
    val library: String,
    val failedName: String?,
    val failedTitle: String?,
    val failedBody: String?,
) {
    companion object {
        fun from(m: Map<*, *>) = FgsFinish(
            kind = m["kind"] as? String ?: "none",
            why = m["why"] as? String,
            done = (m["done"] as? Number)?.toInt() ?: 0,
            total = (m["total"] as? Number)?.toInt() ?: 0,
            added = (m["added"] as? Number)?.toInt() ?: 0,
            failed = (m["failed"] as? Number)?.toInt() ?: 0,
            battery = (m["battery"] as? Number)?.toInt(),
            warm = m["warm"] == true,
            library = m["library"] as? String ?: "Bookshelves",
            failedName = m["failedName"] as? String,
            failedTitle = m["failedTitle"] as? String,
            failedBody = m["failedBody"] as? String,
        )
    }
}
