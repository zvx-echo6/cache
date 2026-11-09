package com.happylittlellc.cache.car

import android.content.Intent
import android.net.Uri
import android.os.Looper
import androidx.car.app.CarContext
import androidx.car.app.model.ListTemplate
import androidx.car.app.model.MessageTemplate
import androidx.car.app.model.Template
import androidx.car.app.navigation.model.MapWithContentTemplate
import androidx.car.app.navigation.model.MessageInfo
import androidx.car.app.navigation.model.NavigationTemplate
import androidx.car.app.navigation.model.RoutingInfo
import androidx.car.app.testing.SessionController
import androidx.car.app.testing.TestCarContext
import androidx.car.app.testing.TestScreenManager
import androidx.car.app.testing.navigation.TestNavigationManager
import androidx.lifecycle.Lifecycle
import org.robolectric.RuntimeEnvironment
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** The car session and its screens against the Car App Library's test host: the templates build within the library's limits. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class CarSessionTest {
    private lateinit var car: TestCarContext

    private fun push(method: String, args: Any?) {
        CarLink.handle(MethodCall(method, args), object : MethodChannel.Result {
            override fun success(result: Any?) {}
            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}
            override fun notImplemented() {}
        })
    }

    private fun trip(phase: String, extra: Map<String, Any?> = emptyMap()): Map<String, Any?> = mapOf<String, Any?>(
        "phase" to phase, "available" to true, "units" to "imperial", "routing" to false, "voiceOn" to true,
        "destination" to mapOf("name" to "Cassia Regional Hospital", "address" to "1501 Hiland Ave", "lat" to 42.5, "lon" to -113.5),
        "routes" to listOf(mapOf("index" to 0, "distanceM" to 24000.0, "durationS" to 1200, "via" to "Via Road 0")),
        "routeIndex" to 0, "position" to mapOf("lat" to 42.5, "lon" to -113.77, "heading" to 90.0),
    ) + extra

    private val guiding = mapOf<String, Any?>(
        "step" to mapOf("turn" to "left", "type" to "left", "cue" to "Turn left onto Road 1.", "road" to "Road 1", "distanceM" to 400.0),
        "remainingM" to 21600.0, "remainingS" to 1080, "etaMs" to 1_794_200_000_000L, "currentRoad" to "Road 0",
    )

    private fun templateOf(screen: androidx.car.app.Screen): Template = screen.onGetTemplate()

    @Before
    fun setUp() {
        CarLink.reset()
        car = TestCarContext.createCarContext(RuntimeEnvironment.getApplication())
    }

    @After
    fun tearDown() = CarLink.reset()

    private fun start(intent: Intent = Intent()): SessionController {
        val c = SessionController(CarSession(startEngine = {}), car, intent)
        // The test library drives the Session's public lifecycle only; the car context's own (which the ScreenManager follows,
        // as the host's does) is moved here too, so screens pushed later are created and started as on a real host.
        car.lifecycleOwner.registry.currentState = Lifecycle.State.CREATED
        c.moveToState(Lifecycle.State.CREATED)
        car.lifecycleOwner.registry.currentState = Lifecycle.State.RESUMED
        c.moveToState(Lifecycle.State.RESUMED)
        shadowOf(Looper.getMainLooper()).idle()
        return c
    }

    private val screens get() = car.getCarService(TestScreenManager::class.java)
    private val nav get() = car.getCarService(TestNavigationManager::class.java)

    @Test
    fun opensOnSavedPlacesOverTheMap() {
        start()
        val home = screens.top
        assertTrue(home is HomeScreen)
        val t = templateOf(home) as MapWithContentTemplate
        assertTrue((t.contentTemplate as ListTemplate).isLoading)
        assertNotNull(t.mapController!!.mapActionStrip)
        assertTrue(CarLink.carConnected)
        assertNotNull(nav.navigationManagerCallback)
    }

    @Test
    fun guidanceStartedOnThePhoneShowsTurnByTurnAndTellsTheHost() {
        start()
        push("trip", trip("guiding", guiding))
        assertTrue(screens.top is NavigationScreen)
        assertEquals(1, nav.navigationStartedCount)
        assertEquals(1, nav.tripsSent.size)
        val t = templateOf(screens.top) as NavigationTemplate
        val info = t.navigationInfo as RoutingInfo
        assertEquals("Turn left onto Road 1.", info.currentStep!!.cue.toString())
        assertNotNull(t.destinationTravelEstimate)
        assertEquals(2, t.actionStrip!!.actions.size)
        // Guidance ends (Stop, arrival on the phone): the host is told and the car goes back to the map.
        push("trip", trip("browsing"))
        assertEquals(1, nav.navigationEndedCount)
        assertTrue(screens.top is HomeScreen)
    }

    @Test
    fun beforeTheFirstPositionTheTurnCardIsLoadingAndArrivalIsAMessage() {
        start()
        push("trip", trip("guiding"))
        val t = templateOf(screens.top) as NavigationTemplate
        assertTrue((t.navigationInfo as RoutingInfo).isLoading)
        push("trip", trip("guiding", guiding + mapOf("arrived" to true)))
        val a = templateOf(screens.top) as NavigationTemplate
        assertEquals("You have arrived", (a.navigationInfo as MessageInfo).title.toString())
    }

    @Test
    fun theHostStoppingNavigationStopsItAtOnce() {
        start()
        push("trip", trip("guiding", guiding))
        nav.navigationManagerCallback!!.onStopNavigation()
        // Stop went to Dart (not attached in this test); the host is told as soon as the trip says guidance ended.
        push("trip", trip("browsing"))
        assertEquals(1, nav.navigationEndedCount)
        assertFalse(screens.top is NavigationScreen)
    }

    @Test
    fun theRoutePreviewListsRoutesWithStartOrSaysWhyNot() {
        start()
        val place = CarPlace("place:1", "Cassia Regional Hospital", null, 42.5, -113.5, null)
        val screen = RoutePreviewScreen(car, CarMapRenderer(car), place)
        push("trip", trip("previewing", mapOf("routing" to true, "routes" to emptyList<Any>())))
        assertTrue(((templateOf(screen) as MapWithContentTemplate).contentTemplate as ListTemplate).isLoading)
        push("trip", trip("previewing"))
        val ready = templateOf(screen) as MapWithContentTemplate
        val list = ready.contentTemplate as ListTemplate
        assertEquals(1, list.singleList!!.items.size)
        assertEquals("Start", ready.actionStrip!!.actions[0].title.toString())
        push("trip", trip("previewing", mapOf("routes" to emptyList<Any>(), "error" to "Waiting for your position")))
        val err = templateOf(screen) as MapWithContentTemplate
        assertEquals("Waiting for your position", (err.contentTemplate as MessageTemplate).message.toString())
    }

    @Test
    fun aNavigationIntentIsReadWhenTheCarOpensCache() {
        val intent = Intent(CarContext.ACTION_NAVIGATE, Uri.parse("geo:0,0?q=Home"))
        start(intent)
        assertTrue(screens.top is HomeScreen)
    }

    @Test
    fun theCarGoingAwayEndsNavigationWithTheHost() {
        val c = start()
        push("trip", trip("guiding", guiding))
        c.moveToState(Lifecycle.State.DESTROYED)
        assertEquals(1, nav.navigationEndedCount)
        assertFalse(CarLink.carConnected)
    }

    @Test
    fun theCarStartsCacheWithNoPhoneActivitySavedPlacesComeFromDartAndThePositionServiceRuns() {
        // No Flutter engine and no MainActivity: Dart answers through the test seam, after a moment as a cold start would.
        val app = RuntimeEnvironment.getApplication()
        shadowOf(app).grantPermissions(android.Manifest.permission.ACCESS_FINE_LOCATION)
        val asked = mutableListOf<String>()
        CarLink.dartForTests = { method, _, done ->
            asked += method
            if (method == "saved") {
                android.os.Handler(Looper.getMainLooper()).postDelayed({
                    done(listOf(mapOf("id" to "place:42.6,-113.7", "name" to "Twin Falls Public Library", "address" to "", "lat" to 42.6, "lon" to -113.7, "distanceM" to 11700.0)))
                }, 2000)
            } else {
                done(null)
            }
        }
        val c = start()
        val home = screens.top as HomeScreen
        assertTrue(((templateOf(home) as MapWithContentTemplate).contentTemplate as ListTemplate).isLoading)
        shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(3))
        val list = ((templateOf(home) as MapWithContentTemplate).contentTemplate as ListTemplate).singleList!!
        assertEquals(1, list.items.size)
        assertTrue("saved" in asked)
        val started = shadowOf(app).nextStartedService
        assertEquals(CarLocationService::class.java.name, started.component!!.className)
        c.moveToState(Lifecycle.State.DESTROYED)
        assertEquals(CarLocationService::class.java.name, shadowOf(app).nextStoppedService.component!!.className)
    }

    @Test
    fun withoutLocationPermissionNoPositionServiceStarts() {
        CarLink.dartForTests = { _, _, done -> done(null) }
        start()
        assertEquals(null, shadowOf(RuntimeEnvironment.getApplication()).nextStartedService)
    }

    @Test
    fun aListenerThatFailsDoesNotStopTheOthers() {
        var heard = 0
        CarLink.addListener(object : CarLink.Listener {
            override fun onTrip(trip: CarTrip) = throw IllegalArgumentException("latitude must be between -90 and 90")
        })
        CarLink.addListener(object : CarLink.Listener {
            override fun onTrip(trip: CarTrip) {
                heard++
            }
        })
        push("trip", trip("browsing"))
        assertEquals(1, heard)
    }

    @Test
    fun dartHelloAnswersWhetherACarIsConnected() {
        var answer: Any? = null
        CarLink.handle(MethodCall("hello", null), object : MethodChannel.Result {
            override fun success(result: Any?) { answer = result }
            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}
            override fun notImplemented() {}
        })
        assertEquals(mapOf("connected" to false), answer)
        assertTrue(CarLink.dartReady)
    }

    @Test
    fun audioFocusIsHeldAboutAsLongAsThePrompt() {
        assertEquals(1500L + 80L * 10, CarAudio.holdMs("Turn left."))
        assertEquals(20_000L, CarAudio.holdMs("x".repeat(1000)))
        assertEquals(android.media.AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE, CarAudio.ATTRIBUTES.usage)
    }
}
