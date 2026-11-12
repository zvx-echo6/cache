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
        assertEquals(listOf(NavRequest(null, null, "Made Up Clinic", start = true)), heard)
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

    @Test
    fun anAddressWithModeAndIntent() {
        val r = NavIntent.parse("geo:0,0?q=1600+Amphitheatre+parkway&mode=b&intent=add_a_stop")!!
        assertEquals("1600 Amphitheatre parkway", r.query)
        assertTrue(r.start)
    }

    @Test
    fun coordinatesWithAName() {
        val r = NavIntent.parse("geo:1.1,2.2?q=Starbucks+on+Main+Street&mode=w&intent=navigation")!!
        assertEquals(1.1, r.lat!!, 0.0)
        assertEquals(2.2, r.lon!!, 0.0)
        assertEquals("Starbucks on Main Street", r.query)
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
}
