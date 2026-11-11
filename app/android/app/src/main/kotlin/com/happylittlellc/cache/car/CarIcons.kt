package com.happylittlellc.cache.car

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import androidx.car.app.model.CarColor
import androidx.car.app.model.CarIcon
import androidx.core.graphics.drawable.IconCompat
import kotlin.math.cos
import kotlin.math.sin

/**
 * The car screen's icons, drawn in code (simple white shapes the host tints or shows on its dark cards), so no image assets are
 * added: the turn arrows for each [CarStep.turn], and the buttons of the action strips.
 */
object CarIcons {
    private const val SIZE = 192
    private val cache = HashMap<String, CarIcon>()

    private fun paint(stroke: Float = 0f) = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        if (stroke > 0) {
            style = Paint.Style.STROKE
            strokeWidth = stroke
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        } else {
            style = Paint.Style.FILL
        }
    }

    private fun icon(key: String, tint: Boolean, draw: (Canvas, Float) -> Unit): CarIcon = cache.getOrPut("$key:$tint") {
        val bmp = Bitmap.createBitmap(SIZE, SIZE, Bitmap.Config.ARGB_8888)
        draw(Canvas(bmp), SIZE.toFloat())
        val b = CarIcon.Builder(IconCompat.createWithBitmap(bmp))
        if (tint) b.setTint(CarColor.DEFAULT)
        b.build()
    }

    /** The turn arrow for the phone's TurnIcon name. */
    fun maneuver(turn: String): CarIcon = when (turn) {
        "slightLeft" -> arrow(turn, -45f)
        "left" -> arrow(turn, -90f)
        "sharpLeft" -> arrow(turn, -135f)
        "slightRight" -> arrow(turn, 45f)
        "right" -> arrow(turn, 90f)
        "sharpRight" -> arrow(turn, 135f)
        "merge", "ramp" -> arrow(turn, 30f)
        "exit" -> arrow(turn, 45f)
        "uTurn" -> uTurn()
        "roundabout" -> roundabout()
        "arrive", "via" -> pin(turn)
        else -> arrow(turn, 0f)
    }

    private fun head(c: Canvas, x: Float, y: Float, angleDeg: Float, s: Float) {
        val a = Math.toRadians(angleDeg.toDouble())
        val len = s * 0.17f
        val wide = s * 0.13f
        val dx = sin(a).toFloat()
        val dy = -cos(a).toFloat()
        val p = Path()
        p.moveTo(x + dx * len * 0.6f, y + dy * len * 0.6f)
        p.lineTo(x - dx * len * 0.5f - dy * wide, y - dy * len * 0.5f + dx * wide)
        p.lineTo(x - dx * len * 0.5f + dy * wide, y - dy * len * 0.5f - dx * wide)
        p.close()
        c.drawPath(p, paint())
    }

    /** A stem up from the bottom, then bent by [angleDeg] (0 straight on, negative to the left), with its head. */
    private fun arrow(key: String, angleDeg: Float): CarIcon = icon("arrow-$key", tint = false) { c, s ->
        val w = s * 0.11f
        val bx = s * 0.5f - (angleDeg / 135f) * s * 0.12f
        val by = s * 0.9f
        val kx = bx
        val ky = if (angleDeg == 0f) s * 0.26f else s * 0.5f
        val a = Math.toRadians(angleDeg.toDouble())
        val len = if (angleDeg == 0f) 0f else s * 0.28f
        val tx = kx + sin(a).toFloat() * len
        val ty = ky - cos(a).toFloat() * len
        val p = Path()
        p.moveTo(bx, by)
        p.lineTo(kx, ky)
        if (len > 0) p.lineTo(tx, ty)
        c.drawPath(p, paint(w))
        head(c, tx, ty, angleDeg, s)
    }

    private fun uTurn(): CarIcon = icon("uturn", tint = false) { c, s ->
        val w = s * 0.11f
        val p = Path()
        p.moveTo(s * 0.64f, s * 0.9f)
        p.lineTo(s * 0.64f, s * 0.42f)
        p.arcTo(RectF(s * 0.3f, s * 0.25f, s * 0.64f, s * 0.59f), 0f, -180f)
        p.lineTo(s * 0.3f, s * 0.62f)
        c.drawPath(p, paint(w))
        head(c, s * 0.3f, s * 0.7f, 180f, s)
    }

    private fun roundabout(): CarIcon = icon("roundabout", tint = false) { c, s ->
        val w = s * 0.1f
        c.drawCircle(s * 0.5f, s * 0.5f, s * 0.2f, paint(w))
        val p = Path()
        p.moveTo(s * 0.5f, s * 0.92f)
        p.lineTo(s * 0.5f, s * 0.7f)
        c.drawPath(p, paint(w))
        val q = Path()
        q.moveTo(s * 0.64f, s * 0.36f)
        q.lineTo(s * 0.8f, s * 0.2f)
        c.drawPath(q, paint(w))
        head(c, s * 0.82f, s * 0.18f, 45f, s)
    }

    private fun pin(key: String): CarIcon = icon("pin-$key", tint = false) { c, s ->
        val p = Path()
        p.moveTo(s * 0.5f, s * 0.92f)
        p.lineTo(s * 0.27f, s * 0.48f)
        p.arcTo(RectF(s * 0.25f, s * 0.12f, s * 0.75f, s * 0.62f), 155f, 230f)
        p.close()
        c.drawPath(p, paint())
        val hole = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.TRANSPARENT; xfermode = android.graphics.PorterDuffXfermode(android.graphics.PorterDuff.Mode.CLEAR) }
        c.drawCircle(s * 0.5f, s * 0.37f, s * 0.1f, hole)
    }

    // ---- buttons -------------------------------------------------------------------------------------------------

    val search: CarIcon get() = icon("search", tint = true) { c, s ->
        val w = s * 0.1f
        c.drawCircle(s * 0.43f, s * 0.43f, s * 0.22f, paint(w))
        val p = Path()
        p.moveTo(s * 0.6f, s * 0.6f)
        p.lineTo(s * 0.82f, s * 0.82f)
        c.drawPath(p, paint(w * 1.2f))
    }

    val zoomIn: CarIcon get() = icon("zoomIn", tint = true) { c, s ->
        val w = s * 0.1f
        val p = Path()
        p.moveTo(s * 0.22f, s * 0.5f); p.lineTo(s * 0.78f, s * 0.5f)
        p.moveTo(s * 0.5f, s * 0.22f); p.lineTo(s * 0.5f, s * 0.78f)
        c.drawPath(p, paint(w))
    }

    val zoomOut: CarIcon get() = icon("zoomOut", tint = true) { c, s ->
        val p = Path()
        p.moveTo(s * 0.22f, s * 0.5f); p.lineTo(s * 0.78f, s * 0.5f)
        c.drawPath(p, paint(s * 0.1f))
    }

    val recenter: CarIcon get() = icon("recenter", tint = true) { c, s ->
        val w = s * 0.08f
        c.drawCircle(s * 0.5f, s * 0.5f, s * 0.25f, paint(w))
        c.drawCircle(s * 0.5f, s * 0.5f, s * 0.09f, paint())
        val p = Path()
        p.moveTo(s * 0.5f, s * 0.08f); p.lineTo(s * 0.5f, s * 0.22f)
        p.moveTo(s * 0.5f, s * 0.78f); p.lineTo(s * 0.5f, s * 0.92f)
        p.moveTo(s * 0.08f, s * 0.5f); p.lineTo(s * 0.22f, s * 0.5f)
        p.moveTo(s * 0.78f, s * 0.5f); p.lineTo(s * 0.92f, s * 0.5f)
        c.drawPath(p, paint(w))
    }

    private fun speaker(c: Canvas, s: Float) {
        val p = Path()
        p.moveTo(s * 0.14f, s * 0.4f)
        p.lineTo(s * 0.3f, s * 0.4f)
        p.lineTo(s * 0.5f, s * 0.22f)
        p.lineTo(s * 0.5f, s * 0.78f)
        p.lineTo(s * 0.3f, s * 0.6f)
        p.lineTo(s * 0.14f, s * 0.6f)
        p.close()
        c.drawPath(p, paint())
    }

    val voiceOn: CarIcon get() = icon("voiceOn", tint = true) { c, s ->
        speaker(c, s)
        val w = s * 0.07f
        c.drawArc(RectF(s * 0.42f, s * 0.32f, s * 0.72f, s * 0.68f), -50f, 100f, false, paint(w))
        c.drawArc(RectF(s * 0.42f, s * 0.18f, s * 0.88f, s * 0.82f), -50f, 100f, false, paint(w))
    }

    val voiceOff: CarIcon get() = icon("voiceOff", tint = true) { c, s ->
        speaker(c, s)
        val w = s * 0.08f
        val p = Path()
        p.moveTo(s * 0.62f, s * 0.38f); p.lineTo(s * 0.86f, s * 0.62f)
        p.moveTo(s * 0.86f, s * 0.38f); p.lineTo(s * 0.62f, s * 0.62f)
        c.drawPath(p, paint(w))
    }

    /** Route overview: a bent route between two dots. */
    val overview: CarIcon get() = icon("overview", tint = true) { c, s ->
        val w = s * 0.08f
        val p = Path()
        p.moveTo(s * 0.26f, s * 0.76f)
        p.cubicTo(s * 0.26f, s * 0.5f, s * 0.7f, s * 0.62f, s * 0.7f, s * 0.3f)
        c.drawPath(p, paint(w))
        c.drawCircle(s * 0.26f, s * 0.76f, s * 0.09f, paint())
        c.drawCircle(s * 0.7f, s * 0.26f, s * 0.09f, paint())
    }
}
