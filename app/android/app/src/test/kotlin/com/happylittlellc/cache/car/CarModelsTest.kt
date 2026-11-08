package com.happylittlellc.cache.car

import androidx.car.app.model.Distance
import androidx.car.app.model.DistanceSpan
import androidx.car.app.model.DurationSpan
import androidx.car.app.navigation.model.Maneuver
import android.text.Spanned
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class CarModelsTest {
    private val guidingMap = mapOf<String, Any?>(
        "phase" to "guiding", "available" to true, "units" to "imperial", "routing" to false,
        "destination" to mapOf("name" to "Cassia Regional Hospital", "address" to "1501 Hiland Ave", "lat" to 42.5, "lon" to -113.5),
        "routes" to listOf(mapOf("index" to 0, "distanceM" to 24000.0, "durationS" to 1200, "via" to "Via Road 0")),
        "routeIndex" to 0, "routeId" to "r1", "voiceOn" to true, "arrived" to false, "rerouting" to false,
        "position" to mapOf("lat" to 42.5, "lon" to -113.77, "heading" to 90.0),
        "step" to mapOf("turn" to "left", "type" to "left", "cue" to "Turn left onto Road 1.", "road" to "Road 1", "distanceM" to 400.0),
        "then" to mapOf("turn" to "right", "type" to "right", "cue" to "Turn right onto Road 2.", "road" to "Road 2", "distanceM" to 8000.0),
        "currentRoad" to "Road 0", "remainingM" to 21600.0, "remainingS" to 1080, "etaMs" to 1_794_200_000_000L,
    )

    @Test
    fun tripIsReadFromWhatDartPushes() {
        val t = CarTrip.from(guidingMap)
        assertTrue(t.guiding)
        assertTrue(t.imperial)
        assertEquals("Cassia Regional Hospital", t.destinationName)
        assertEquals(1, t.routes.size)
        assertEquals(1200L, t.routes[0].durationS)
        assertEquals("left", t.step!!.turn)
        assertEquals("Road 1", t.step!!.road)
        assertEquals(90.0, t.heading!!, 0.0)
        assertEquals(1_794_200_000_000L, t.etaMs)
    }

    @Test
    fun anEmptyOrOddMapIsBrowsing() {
        val t = CarTrip.from(mapOf("phase" to null, "routes" to "x", "step" to 3))
        assertEquals("browsing", t.phase)
        assertTrue(t.routes.isEmpty())
        assertNull(t.step)
        assertFalse(t.guiding)
    }

    @Test
    fun distancesAreInThePhoneUnitsAndRoundedLikeThePhone() {
        val ft = CarModels.distance(120.0, imperial = true)
        assertEquals(Distance.UNIT_FEET, ft.displayUnit)
        assertEquals(400.0, ft.displayDistance, 0.0)
        val mi = CarModels.distance(4023.36, imperial = true)
        assertEquals(Distance.UNIT_MILES_P1, mi.displayUnit)
        assertEquals(2.5, mi.displayDistance, 0.0)
        assertEquals(Distance.UNIT_MILES, CarModels.distance(40000.0, imperial = true).displayUnit)
        val m = CarModels.distance(87.0, imperial = false)
        assertEquals(Distance.UNIT_METERS, m.displayUnit)
        assertEquals(90.0, m.displayDistance, 0.0)
        val km = CarModels.distance(1530.0, imperial = false)
        assertEquals(Distance.UNIT_KILOMETERS_P1, km.displayUnit)
        assertEquals(1.5, km.displayDistance, 0.0)
        assertEquals("0.2 mi", CarDistanceText.of(321.9, true))
        assertEquals("150 m", CarDistanceText.of(149.0, false))
    }

    @Test
    fun turnsMapToTheLibraryManeuvers() {
        assertEquals(Maneuver.TYPE_DEPART, CarModels.maneuverType("start", "start"))
        assertEquals(Maneuver.TYPE_TURN_NORMAL_LEFT, CarModels.maneuverType("left", "left"))
        assertEquals(Maneuver.TYPE_KEEP_RIGHT, CarModels.maneuverType("slightRight", "stay_right"))
        assertEquals(Maneuver.TYPE_TURN_SLIGHT_RIGHT, CarModels.maneuverType("slightRight", "slight_right"))
        assertEquals(Maneuver.TYPE_U_TURN_RIGHT, CarModels.maneuverType("uTurn", "uturn_right"))
        assertEquals(Maneuver.TYPE_ROUNDABOUT_ENTER_CCW, CarModels.maneuverType("roundabout", "roundabout_enter"))
        assertEquals(Maneuver.TYPE_ROUNDABOUT_EXIT_CCW, CarModels.maneuverType("roundabout", "roundabout_exit"))
        assertEquals(Maneuver.TYPE_OFF_RAMP_NORMAL_LEFT, CarModels.maneuverType("exit", "exit_left"))
        assertEquals(Maneuver.TYPE_ON_RAMP_NORMAL_RIGHT, CarModels.maneuverType("ramp", "ramp_right"))
        assertEquals(Maneuver.TYPE_MERGE_SIDE_UNSPECIFIED, CarModels.maneuverType("merge", "merge"))
        assertEquals(Maneuver.TYPE_DESTINATION_RIGHT, CarModels.maneuverType("arrive", "destination_right"))
        assertEquals(Maneuver.TYPE_NAME_CHANGE, CarModels.maneuverType("straight", "becomes"))
        assertEquals(Maneuver.TYPE_STRAIGHT, CarModels.maneuverType("offroad", "none"))
        assertEquals(Maneuver.TYPE_UNKNOWN, CarModels.maneuverType("nothing", ""))
    }

    @Test
    fun routingInfoHasTheTurnAndTheNextOneOrIsLoading() {
        val t = CarTrip.from(guidingMap)
        val info = CarModels.routingInfo(t) { CarIcons.maneuver(it) }
        assertFalse(info.isLoading)
        assertEquals("Turn left onto Road 1.", info.currentStep!!.cue.toString())
        assertEquals(Maneuver.TYPE_TURN_NORMAL_LEFT, info.currentStep!!.maneuver!!.type)
        assertNotNull(info.currentStep!!.maneuver!!.icon)
        assertEquals(Distance.UNIT_FEET, info.currentDistance!!.displayUnit)
        assertEquals("Turn right onto Road 2.", info.nextStep!!.cue.toString())
        val loading = CarModels.routingInfo(t.copy(step = null, then = null)) { null }
        assertTrue(loading.isLoading)
    }

    @Test
    fun travelEstimateAndTripForTheCluster() {
        val t = CarTrip.from(guidingMap)
        val est = CarModels.travelEstimate(t)!!
        assertEquals(1080L, est.remainingTimeSeconds)
        assertEquals(Distance.UNIT_MILES, est.remainingDistance!!.displayUnit)
        val trip = CarModels.trip(t, { CarIcons.maneuver(it) }, nowMs = 1_794_199_000_000L)
        assertFalse(trip.isLoading)
        assertEquals(1, trip.steps.size)
        assertEquals("Cassia Regional Hospital", trip.destinations[0].name.toString())
        assertEquals("Road 0", trip.currentRoad.toString())
        assertTrue(CarModels.trip(t.copy(step = null), { null }).isLoading)
        assertNull(CarModels.travelEstimate(t.copy(remainingM = null)))
    }

    @Test
    fun routeTitleLetsTheHostFormatTimeAndDistance() {
        val r = CarTrip.from(guidingMap).routes[0]
        val title = CarModels.routeTitle(r, imperial = true) as Spanned
        assertEquals(1, title.getSpans(0, title.length, DurationSpan::class.java).size)
        assertEquals(1, title.getSpans(0, title.length, DistanceSpan::class.java).size)
        assertEquals(1200L, title.getSpans(0, title.length, DurationSpan::class.java)[0].durationSeconds)
    }

    @Test
    fun placesAreReadAndBadOnesSkipped() {
        val list = CarPlace.list(listOf(
            mapOf("id" to "place:1", "name" to "Home", "address" to "", "lat" to 42.6, "lon" to -113.7, "distanceM" to 1200.0),
            mapOf("id" to "place:2", "name" to "No position"),
            "junk",
        ))
        assertEquals(1, list.size)
        assertEquals("Home", list[0].name)
        assertNull(list[0].address)
    }
}
