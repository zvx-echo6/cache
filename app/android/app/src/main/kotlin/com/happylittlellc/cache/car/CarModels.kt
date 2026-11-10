package com.happylittlellc.cache.car

import android.text.SpannableString
import android.text.Spanned
import androidx.car.app.model.CarIcon
import androidx.car.app.model.DateTimeWithZone
import androidx.car.app.model.Distance
import androidx.car.app.model.DistanceSpan
import androidx.car.app.model.DurationSpan
import androidx.car.app.navigation.model.Destination
import androidx.car.app.navigation.model.Maneuver
import androidx.car.app.navigation.model.RoutingInfo
import androidx.car.app.navigation.model.Step
import androidx.car.app.navigation.model.TravelEstimate
import androidx.car.app.navigation.model.Trip
import java.util.TimeZone
import kotlin.math.max
import kotlin.math.roundToLong

/** The Car App Library's models, made from the phone's trip. Pure: no car context, so they are tested on their own. */
object CarModels {
    private const val M_PER_MILE = 1609.344
    private const val FT_PER_M = 3.28084

    /** A distance in the phone's units, rounded as the phone's banner rounds it (lib/nav/units.dart). */
    fun distance(meters: Double, imperial: Boolean): Distance {
        val m = max(0.0, meters)
        if (imperial) {
            val ft = m * FT_PER_M
            val mi = m / M_PER_MILE
            return when {
                ft < 528 -> Distance.create(roundTo(ft, if (ft < 100) 10 else 50), Distance.UNIT_FEET)
                mi < 10 -> Distance.create(Math.round(mi * 10) / 10.0, Distance.UNIT_MILES_P1)
                else -> Distance.create(Math.round(mi).toDouble(), Distance.UNIT_MILES)
            }
        }
        return when {
            m < 1000 -> Distance.create(roundTo(m, if (m < 100) 10 else 50), Distance.UNIT_METERS)
            m < 10000 -> Distance.create(Math.round(m / 100) / 10.0, Distance.UNIT_KILOMETERS_P1)
            else -> Distance.create(Math.round(m / 1000).toDouble(), Distance.UNIT_KILOMETERS)
        }
    }

    private fun roundTo(v: Double, step: Int): Double = (Math.round(v / step) * step).toDouble()

    /** The Car App Library's maneuver type for the phone's turn ([CarStep.turn]) and the core's maneuver type ([CarStep.type]). */
    fun maneuverType(turn: String, type: String): Int = when (turn) {
        "start" -> Maneuver.TYPE_DEPART
        "slightLeft" -> if (type == "stay_left") Maneuver.TYPE_KEEP_LEFT else Maneuver.TYPE_TURN_SLIGHT_LEFT
        "left" -> Maneuver.TYPE_TURN_NORMAL_LEFT
        "sharpLeft" -> Maneuver.TYPE_TURN_SHARP_LEFT
        "slightRight" -> if (type == "stay_right") Maneuver.TYPE_KEEP_RIGHT else Maneuver.TYPE_TURN_SLIGHT_RIGHT
        "right" -> Maneuver.TYPE_TURN_NORMAL_RIGHT
        "sharpRight" -> Maneuver.TYPE_TURN_SHARP_RIGHT
        "uTurn" -> if (type.contains("right")) Maneuver.TYPE_U_TURN_RIGHT else Maneuver.TYPE_U_TURN_LEFT
        "roundabout" -> if (type.contains("exit")) Maneuver.TYPE_ROUNDABOUT_EXIT_CCW else Maneuver.TYPE_ROUNDABOUT_ENTER_CCW
        "merge" -> when {
            type.contains("left") -> Maneuver.TYPE_MERGE_LEFT
            type.contains("right") -> Maneuver.TYPE_MERGE_RIGHT
            else -> Maneuver.TYPE_MERGE_SIDE_UNSPECIFIED
        }
        "ramp" -> when {
            type.contains("left") -> Maneuver.TYPE_ON_RAMP_NORMAL_LEFT
            type.contains("right") -> Maneuver.TYPE_ON_RAMP_NORMAL_RIGHT
            else -> Maneuver.TYPE_ON_RAMP_SLIGHT_RIGHT
        }
        "exit" -> if (type.contains("left")) Maneuver.TYPE_OFF_RAMP_NORMAL_LEFT else Maneuver.TYPE_OFF_RAMP_NORMAL_RIGHT
        "ferry" -> Maneuver.TYPE_FERRY_BOAT
        "via" -> Maneuver.TYPE_DESTINATION
        "arrive" -> when {
            type.contains("left") -> Maneuver.TYPE_DESTINATION_LEFT
            type.contains("right") -> Maneuver.TYPE_DESTINATION_RIGHT
            else -> Maneuver.TYPE_DESTINATION
        }
        "straight" -> if (type == "becomes") Maneuver.TYPE_NAME_CHANGE else Maneuver.TYPE_STRAIGHT
        "offroad" -> Maneuver.TYPE_STRAIGHT
        else -> Maneuver.TYPE_UNKNOWN
    }

    fun step(s: CarStep, icon: CarIcon?): Step {
        val man = Maneuver.Builder(maneuverType(s.turn, s.type))
        if (icon != null) man.setIcon(icon)
        val b = Step.Builder(s.cue.ifBlank { " " }).setManeuver(man.build())
        s.road?.let { b.setRoad(it) }
        return b.build()
    }

    /** The turn card: the next maneuver and how far, and the one after; loading while the first position or a new route comes. */
    fun routingInfo(t: CarTrip, icon: (String) -> CarIcon?): RoutingInfo {
        val s = t.step ?: return RoutingInfo.Builder().setLoading(true).build()
        val b = RoutingInfo.Builder().setCurrentStep(step(s, icon(s.turn)), distance(s.distanceM, t.imperial))
        t.then?.let { b.setNextStep(step(it, icon(it.turn))) }
        return b.build()
    }

    /** The arrival estimate, or null while the trip is not known yet. */
    fun travelEstimate(t: CarTrip, nowMs: Long = System.currentTimeMillis()): TravelEstimate? {
        val m = t.remainingM ?: return null
        val s = t.remainingS ?: return null
        val eta = t.etaMs ?: (nowMs + s * 1000)
        return TravelEstimate.Builder(distance(m, t.imperial), DateTimeWithZone.create(eta, TimeZone.getDefault()))
            .setRemainingTimeSeconds(max(0L, s))
            .build()
    }

    /** What the host passes to the instrument cluster and heads-up display (NavigationManager.updateTrip). */
    fun trip(t: CarTrip, icon: (String) -> CarIcon?, nowMs: Long = System.currentTimeMillis()): Trip {
        val b = Trip.Builder()
        val est = travelEstimate(t, nowMs)
        val s = t.step
        if (s == null || est == null) {
            b.setLoading(true)
            return b.build()
        }
        val dest = Destination.Builder().setName(t.destinationName ?: "Destination")
        t.destinationAddress?.let { dest.setAddress(it) }
        b.addDestination(dest.build(), est)
        // The time to the step: its share of the time left, as the core's estimate goes.
        val remainingM = t.remainingM ?: s.distanceM
        val stepS = if (remainingM > 0) ((t.remainingS ?: 0L) * (s.distanceM / remainingM)).roundToLong() else 0L
        val stepEst = TravelEstimate.Builder(distance(s.distanceM, t.imperial), DateTimeWithZone.create(nowMs + stepS * 1000, TimeZone.getDefault()))
            .setRemainingTimeSeconds(max(0L, stepS))
            .build()
        b.addStep(step(s, icon(s.turn)), stepEst)
        t.currentRoad?.let { b.setCurrentRoad(it) }
        return b.build()
    }

    /** "24 min · 18.5 mi" with the host formatting the time and distance for the car. */
    fun routeTitle(r: CarRoute, imperial: Boolean): CharSequence {
        val text = SpannableString("  ·  ")
        text.setSpan(DurationSpan.create(r.durationS), 0, 1, Spanned.SPAN_INCLUSIVE_INCLUSIVE)
        text.setSpan(DistanceSpan.create(distance(r.distanceM, imperial)), 4, 5, Spanned.SPAN_INCLUSIVE_INCLUSIVE)
        return text
    }

    /** "2.4 mi" for a place's distance, or null. */
    fun placeDistance(meters: Double?, imperial: Boolean): CharSequence? {
        if (meters == null) return null
        val text = SpannableString(" ")
        text.setSpan(DistanceSpan.create(distance(meters, imperial)), 0, 1, Spanned.SPAN_INCLUSIVE_INCLUSIVE)
        return text
    }
}
