package com.happylittlellc.cache.car

import android.content.Intent
import android.net.Uri
import androidx.car.app.CarContext
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The navigation intent formats from Google's "Gemini and Google Assistant navigation app intents" page (NF-6). */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class NavIntentTest {
    @Before
    fun setUp() = CarLink.reset()

    @After
    fun tearDown() = CarLink.reset()

    // Bug: a navigation request delivered to the phone's activity. With no car connected it is taken (so Flutter never sees
    // it) and dropped.
    @Test
    fun aRequestThatReachesThePhoneWithNoCarIsTakenAndDropped() {
        var heard = 0
        CarLink.addListener(object : CarLink.Listener {
            override fun onNavRequest(req: NavRequest) {
                heard++
            }
        })
        assertTrue(NavIntent.fromPhone(Intent(CarContext.ACTION_NAVIGATE, Uri.parse("geo:0,0?q=Made+Up+Clinic"))))
        assertTrue(NavIntent.fromPhone(Intent(CarContext.ACTION_NAVIGATE, Uri.parse("geo:42.5,-113.5"))))
        // One that cannot be read is still a navigation request, and still kept from Flutter.
        assertTrue(NavIntent.fromPhone(Intent(CarContext.ACTION_NAVIGATE, Uri.parse("geo:0,0"))))
        assertTrue(NavIntent.fromPhone(Intent(CarContext.ACTION_NAVIGATE)))
        assertEquals(0, heard)
        // Anything else is the activity's own business.
        assertFalse(NavIntent.fromPhone(Intent(Intent.ACTION_MAIN)))
        assertFalse(NavIntent.fromPhone(Intent(Intent.ACTION_VIEW, Uri.parse("geo:0,0?q=Made+Up+Clinic"))))
        assertFalse(NavIntent.fromPhone(null))
    }

    @Test
    fun aRequestThatReachesThePhoneWithACarConnectedGoesToTheCar() {
        val heard = mutableListOf<NavRequest>()
        CarLink.addListener(object : CarLink.Listener {
            override fun onNavRequest(req: NavRequest) {
                heard += req
            }
        })
        CarLink.setCarConnected(true)
        assertTrue(NavIntent.fromPhone(Intent(CarContext.ACTION_NAVIGATE, Uri.parse("geo:0,0?q=Made+Up+Clinic"))))
        assertEquals(listOf(NavRequest(null, null, "Made Up Clinic", NavKind.NAVIGATION)), heard)
    }

    @Test
    fun theActivityStartsOnAPlainLaunchWhenARequestOpenedIt() {
        val asked = Intent(CarContext.ACTION_NAVIGATE, Uri.parse("geo:0,0?q=Made+Up+Clinic")).putExtra("kept", 7)
        val plain = NavIntent.plainLaunch(asked)
        assertEquals(Intent.ACTION_MAIN, plain.action)
        assertNull(plain.data)
        assertEquals(7, plain.getIntExtra("kept", 0))
        assertFalse(NavIntent.fromPhone(plain))
    }

    @Test
    fun aPlaceByName() {
        val r = NavIntent.parse("geo:0,0?q=Googleplex")!!
        assertNull(r.lat)
        assertEquals("Googleplex", r.query)
        assertTrue(r.start)
    }

    // Bug: "add a stop" was read as a plain navigation request, so the route was replaced. It is a stop: the route keeps its
    // destination.
    @Test
    fun anAddressWithModeAndIntent() {
        val r = NavIntent.parse("geo:0,0?q=1600+Amphitheatre+parkway&mode=b&intent=add_a_stop")!!
        assertEquals("1600 Amphitheatre parkway", r.query)
        assertEquals(NavKind.ADD_A_STOP, r.kind)
        assertTrue(r.addStop)
        assertTrue(r.start)
    }

    @Test
    fun addAStopWithCoordinatesAndAName() {
        val r = NavIntent.parse("geo:42.6,-113.6?q=Place+1&intent=add_a_stop")!!
        assertEquals(42.6, r.lat!!, 0.0)
        assertEquals(-113.6, r.lon!!, 0.0)
        assertEquals("Place 1", r.query)
        assertEquals(NavKind.ADD_A_STOP, r.kind)
    }

    @Test
    fun theIntentValuesGooglesPageLists() {
        assertEquals(NavKind.NAVIGATION, NavIntent.parse("geo:0,0?q=Place+1&intent=navigation")!!.kind)
        assertEquals(NavKind.DIRECTIONS, NavIntent.parse("geo:0,0?q=Place+1&intent=directions")!!.kind)
        assertEquals(NavKind.ADD_A_STOP, NavIntent.parse("geo:0,0?q=Place+1&intent=add_a_stop")!!.kind)
        // None: the page's default, navigation.
        assertEquals(NavKind.NAVIGATION, NavIntent.parse("geo:0,0?q=Place+1")!!.kind)
        // An unknown value: as before, a plain navigation request that starts.
        val other = NavIntent.parse("geo:0,0?q=Place+1&intent=something_new")!!
        assertEquals(NavKind.NAVIGATION, other.kind)
        assertTrue(other.start)
        assertFalse(other.addStop)
        // Navigation and directions are not stops.
        assertFalse(NavIntent.parse("geo:0,0?q=Place+1&intent=navigation")!!.addStop)
        assertFalse(NavIntent.parse("geo:0,0?q=Place+1&intent=directions")!!.addStop)
    }

    @Test
    fun coordinatesWithAName() {
        val r = NavIntent.parse("geo:1.1,2.2?q=Starbucks+on+Main+Street&mode=w&intent=navigation")!!
        assertEquals(1.1, r.lat!!, 0.0)
        assertEquals(2.2, r.lon!!, 0.0)
        assertEquals("Starbucks on Main Street", r.query)
        assertEquals(NavKind.NAVIGATION, r.kind)
        assertTrue(r.start)
    }

    @Test
    fun coordinatesOnly() {
        val r = NavIntent.parse("geo:47.61594547836694,-122.20373173098756?entry=assistant")!!
        assertEquals(47.61594547836694, r.lat!!, 1e-12)
        assertNull(r.query)
    }

    @Test
    fun coordinatesInTheQueryWithALabel() {
        val r = NavIntent.parse("geo:0,0?q=42.53,-113.79(Burley%20Library)")!!
        assertEquals(42.53, r.lat!!, 0.0)
        assertEquals(-113.79, r.lon!!, 0.0)
        assertEquals("Burley Library", r.query)
    }

    @Test
    fun directionsOnlyDoesNotStart() {
        assertFalse(NavIntent.parse("geo:0,0?q=coffee+shop&intent=directions")!!.start)
    }

    @Test
    fun theOfflineSchemeAndNonsense() {
        assertEquals("Boise", NavIntent.parse("geo.offline:0,0?q=Boise")!!.query)
        assertNull(NavIntent.parse("geo:0,0"))
        assertNull(NavIntent.parse("https://example.com/?q=x"))
        assertNull(NavIntent.parse("nonsense"))
    }

    @Test
    fun onlyTheCarNavigateActionIsANavigationRequest() {
        val ok = Intent(CarContext.ACTION_NAVIGATE, Uri.parse("geo:0,0?q=Burley"))
        assertEquals("Burley", NavIntent.parse(ok)!!.query)
        assertNull(NavIntent.parse(Intent(Intent.ACTION_VIEW, Uri.parse("geo:0,0?q=Burley"))))
        assertNull(NavIntent.parse(null as Intent?))
    }

    private fun act(code: String) = NavIntent.parseAction("geo.action:?act=$code")

    @Test
    fun exitNavigationIsRead() = assertEquals(CarAction.ExitNavigation, act("exit_navigation"))

    @Test
    fun muteIsRead() = assertEquals(CarAction.Mute, act("mute"))

    @Test
    fun unmuteIsRead() = assertEquals(CarAction.Unmute, act("unmute"))

    @Test
    fun routeOverviewIsRead() = assertEquals(CarAction.RouteOverview, act("route_overview"))

    @Test
    fun etaIsRead() = assertEquals(CarAction.Answer("eta"), act("eta"))

    @Test
    fun timeToDestinationIsRead() = assertEquals(CarAction.Answer("eta"), act("time_to_destination"))

    @Test
    fun distanceToDestinationIsRead() = assertEquals(CarAction.Answer("distance"), act("distance_to_destination"))

    @Test
    fun queryNextTurnIsRead() = assertEquals(CarAction.Answer("turn"), act("query_next_turn"))

    @Test
    fun distanceToNextTurnIsRead() = assertEquals(CarAction.Answer("turn"), act("distance_to_next_turn"))

    @Test
    fun timeToNextTurnIsRead() = assertEquals(CarAction.Answer("turn"), act("time_to_next_turn"))

    @Test
    fun queryDestinationIsRead() = assertEquals(CarAction.Answer("destination"), act("query_destination"))

    @Test
    fun anUnknownActionIsUnsupported() {
        assertEquals(CarAction.Unsupported("follow_mode"), act("follow_mode"))
        assertEquals(CarAction.Unsupported("avoid_tolls"), act("avoid_tolls"))
    }

    @Test
    fun aMissingActionIsUnsupported() {
        assertEquals(CarAction.Unsupported(null), NavIntent.parseAction("geo.action:"))
        assertEquals(CarAction.Unsupported(null), NavIntent.parseAction("geo.action:?other=1"))
        assertEquals(CarAction.Unsupported(null), NavIntent.parseAction("geo.action:?act="))
    }

    @Test
    fun onlyAViewIntentWithTheActionSchemeIsAnAction() {
        assertEquals(CarAction.Mute, NavIntent.parseAction(Intent(Intent.ACTION_VIEW, Uri.parse("geo.action:?act=mute"))))
        assertNull(NavIntent.parseAction(Intent(CarContext.ACTION_NAVIGATE, Uri.parse("geo.action:?act=mute"))))
        assertNull(NavIntent.parseAction(Intent(Intent.ACTION_VIEW, Uri.parse("geo:0,0?q=Burley"))))
        assertNull(NavIntent.parseAction("geo:0,0?q=Burley"))
        assertNull(NavIntent.parseAction(null as Intent?))
    }

    // An action that reaches the phone's activity is kept from Flutter; a connected car's session takes it, otherwise it is dropped.
    @Test
    fun anActionThatReachesThePhoneIsTakenAndGoesToTheCarWhenOneIsConnected() {
        val heard = mutableListOf<CarAction>()
        CarLink.addListener(object : CarLink.Listener {
            override fun onCarAction(action: CarAction) {
                heard += action
            }
        })
        assertTrue(NavIntent.fromPhone(Intent(Intent.ACTION_VIEW, Uri.parse("geo.action:?act=mute"))))
        assertEquals(0, heard.size)
        CarLink.setCarConnected(true)
        assertTrue(NavIntent.fromPhone(Intent(Intent.ACTION_VIEW, Uri.parse("geo.action:?act=mute"))))
        assertEquals(listOf<CarAction>(CarAction.Mute), heard)
    }
}
