package com.happylittlellc.cache.car

import android.content.Intent
import android.net.Uri
import android.os.Looper
import android.os.IBinder
import androidx.car.app.CarContext
import androidx.car.app.HostDispatcher
import androidx.car.app.ICarHost
import androidx.car.app.navigation.INavigationHost
import androidx.car.app.navigation.NavigationManagerCallback
import androidx.car.app.serialization.Bundleable
import androidx.car.app.model.ListTemplate
import androidx.car.app.model.MessageTemplate
import androidx.car.app.model.Row
import androidx.car.app.model.SearchTemplate
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
import org.junit.Assert.assertNull
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

    private fun start(intent: Intent = Intent(), session: CarSession = CarSession(startEngine = {})): SessionController {
        val c = SessionController(session, car, intent)
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

    private fun place(n: Int, name: String = "Place $n"): Map<String, Any?> =
        mapOf("id" to "place:$n", "name" to name, "address" to "", "lat" to 42.0 + n, "lon" to -113.0, "distanceM" to 1000.0 * n)

    private fun savedList(screen: androidx.car.app.Screen): ListTemplate = (templateOf(screen) as MapWithContentTemplate).contentTemplate as ListTemplate

    private fun searchRows(screen: androidx.car.app.Screen): List<String> =
        (templateOf(screen) as SearchTemplate).itemList!!.items.map { (it as Row).title.toString() }

    @Test
    fun opensOnTheWholeMapWithSearchAndSavedPlacesButtons() {
        val asked = mutableListOf<String>()
        CarLink.dartForTests = { method, _, done ->
            asked += method
            done(null)
        }
        start()
        val home = screens.top
        assertTrue(home is HomeScreen)
        val t = templateOf(home) as NavigationTemplate
        // The map only: no guidance card.
        assertEquals(null, t.navigationInfo)
        // Search, then Saved places: icons with no words.
        val actions = t.actionStrip!!.actions
        assertEquals(2, actions.size)
        assertEquals(CarIcons.search, actions[0].icon)
        assertEquals(CarIcons.saved, actions[1].icon)
        for (a in actions) assertEquals(null, a.title)
        // The map buttons: pan, zoom in, zoom out.
        assertEquals(3, t.mapActionStrip!!.actions.size)
        assertEquals(androidx.car.app.model.Action.TYPE_PAN, t.mapActionStrip!!.actions[0].type)
        // Home does not ask the phone for saved places.
        assertFalse("saved" in asked)
        assertTrue(CarLink.carConnected)
        assertNotNull(nav.navigationManagerCallback)
    }

    @Test
    fun theHomeButtonsOpenSearchAndSavedPlaces() {
        CarLink.dartForTests = { _, _, done -> done(null) }
        start()
        val home = screens.top as HomeScreen
        home.openSaved()
        assertTrue(screens.top is SavedPlacesScreen)
        screens.pop()
        assertTrue(screens.top is HomeScreen)
        home.openSearch()
        assertTrue(screens.top is SearchScreen)
    }

    @Test
    fun theButtonsThatMustStayDoNotFadeOut() {
        val persistent = androidx.car.app.model.Action.FLAG_IS_PERSISTENT
        val primary = androidx.car.app.model.Action.FLAG_PRIMARY
        CarLink.dartForTests = { method, _, done -> done(if (method == "saved") (1..2).map { place(it) } else null) }
        start()
        // Home: Search and Saved places both stay on the map.
        val home = screens.top as HomeScreen
        val homeActions = (templateOf(home) as NavigationTemplate).actionStrip!!.actions
        assertEquals(2, homeActions.size)
        for (a in homeActions) assertEquals(persistent, a.flags and persistent)
        // Saved places: its Search button stays.
        home.openSaved()
        val saved = screens.top as SavedPlacesScreen
        shadowOf(Looper.getMainLooper()).idle()
        val savedActions = (templateOf(saved) as MapWithContentTemplate).actionStrip!!.actions
        assertEquals(1, savedActions.size)
        assertEquals(persistent, savedActions[0].flags and persistent)
        // Route preview: Start is the primary action and stays.
        val preview = RoutePreviewScreen(car, CarMapRenderer(car), CarPlace("place:1", "Cassia Regional Hospital", null, 42.5, -113.5, null))
        push("trip", trip("previewing"))
        val startAction = (templateOf(preview) as MapWithContentTemplate).actionStrip!!.actions[0]
        assertEquals("Start", startAction.title.toString())
        assertEquals(primary or persistent, startAction.flags and (primary or persistent))
    }

    @Test
    fun savedPlacesIsAListOverTheMapThatBackCloses() {
        CarLink.dartForTests = { method, _, done -> done(if (method == "saved") (1..8).map { place(it) } else null) }
        start()
        (screens.top as HomeScreen).openSaved()
        val saved = screens.top as SavedPlacesScreen
        // Asked for, not answered yet.
        assertTrue(savedList(saved).isLoading)
        shadowOf(Looper.getMainLooper()).idle()
        val t = templateOf(saved) as MapWithContentTemplate
        val list = t.contentTemplate as ListTemplate
        assertEquals("Saved places", list.header!!.title.toString())
        assertEquals(androidx.car.app.model.Action.TYPE_BACK, list.header!!.startHeaderAction!!.type)
        // No more rows than the screen's limit, in the phone's order.
        assertEquals(SavedPlacesScreen.MAX_ROWS, list.singleList!!.items.size)
        assertEquals("Place 1", (list.singleList!!.items[0] as Row).title.toString())
        // Search is its one button, and the map keeps its own.
        assertEquals(1, t.actionStrip!!.actions.size)
        assertEquals(CarIcons.search, t.actionStrip!!.actions[0].icon)
        assertNotNull(t.mapController!!.mapActionStrip)
    }

    @Test
    fun savedPlacesWithNoneSaysSo() {
        CarLink.dartForTests = { method, _, done -> done(if (method == "saved") emptyList<Any>() else null) }
        start()
        (screens.top as HomeScreen).openSaved()
        shadowOf(Looper.getMainLooper()).idle()
        val list = savedList(screens.top).singleList!!
        assertEquals(0, list.items.size)
        assertEquals("No saved places yet. Search for a place to go.", list.noItemsMessage.toString())
    }

    @Test
    fun theEmptySearchBoxListsSavedPlacesAndTypingReplacesThem() {
        CarLink.dartForTests = { method, _, done ->
            when (method) {
                "saved" -> done((1..8).map { place(it) })
                "search" -> done(listOf(place(20, "Found 20")))
                else -> done(null)
            }
        }
        start()
        (screens.top as HomeScreen).openSearch()
        val search = screens.top as SearchScreen
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals((1..SearchScreen.MAX_ROWS).map { "Place $it" }, searchRows(search))
        // The keyboard still opens with the empty box, as before.
        assertTrue((templateOf(search) as SearchTemplate).isShowKeyboardByDefault)
        // Typing: the places found take the list's place, after the usual wait.
        search.textChanged("found")
        shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(1))
        assertEquals(listOf("Found 20"), searchRows(search))
        // The box cleared: the saved places again.
        search.textChanged("")
        shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(1))
        assertEquals((1..SearchScreen.MAX_ROWS).map { "Place $it" }, searchRows(search))
    }

    @Test
    fun aLateSavedAnswerDoesNotReplaceWhatWasFound() {
        CarLink.dartForTests = { method, _, done ->
            when (method) {
                "saved" -> android.os.Handler(Looper.getMainLooper()).postDelayed({ done(listOf(place(1), place(2))) }, 2000)
                "search" -> done(listOf(place(20, "Found 20")))
                else -> done(null)
            }
        }
        start()
        (screens.top as HomeScreen).openSearch()
        val search = screens.top as SearchScreen
        search.submitted("found")
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(listOf("Found 20"), searchRows(search))
        // The saved places arrive now: the places found stay.
        shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(3))
        assertEquals(listOf("Found 20"), searchRows(search))
        // They are there once the box is cleared.
        search.submitted("")
        assertEquals(listOf("Place 1", "Place 2"), searchRows(search))
    }

    @Test
    fun theEmptySearchBoxWithNoSavedPlacesIsEmptyAsBefore() {
        CarLink.dartForTests = { method, _, done -> done(if (method == "saved") emptyList<Any>() else null) }
        start()
        (screens.top as HomeScreen).openSearch()
        shadowOf(Looper.getMainLooper()).idle()
        val items = (templateOf(screens.top) as SearchTemplate).itemList!!
        assertEquals(0, items.items.size)
        assertEquals(null, items.noItemsMessage)
    }

    @Test
    fun searchOpenedWithPlacesFoundDoesNotAskForSavedPlaces() {
        val asked = mutableListOf<String>()
        CarLink.dartForTests = { method, _, done ->
            asked += method
            done(null)
        }
        start()
        val search = SearchScreen(car, CarMapRenderer(car), "found", CarPlace.list(listOf(place(20, "Found 20"))))
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(listOf("Found 20"), searchRows(search))
        assertFalse("saved" in asked)
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
        // End route, Route overview, the voice switch.
        assertEquals(3, t.actionStrip!!.actions.size)
        assertEquals("End route", t.actionStrip!!.actions[0].title.toString())
        // The map buttons: pan, zoom in, zoom out (Recenter joins once the map was moved).
        assertEquals(3, t.mapActionStrip!!.actions.size)
        assertEquals(androidx.car.app.model.Action.TYPE_PAN, t.mapActionStrip!!.actions[0].type)
        // The host's own arrival time, remaining time and distance, in the phone's time zone.
        val est = t.destinationTravelEstimate!!
        assertEquals(1_794_200_000_000L, est.arrivalTimeAtDestination!!.timeSinceEpochMillis)
        assertEquals(java.util.TimeZone.getDefault().getOffset(1_794_200_000_000L) / 1000, est.arrivalTimeAtDestination!!.zoneOffsetSeconds)
        assertEquals(1080L, est.remainingTimeSeconds)
        assertEquals(13.0, est.remainingDistance!!.displayDistance, 0.0)
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

    // Bug: after another navigation source took over, the car kept the old turn strip and no route could be started.
    @Test
    fun theHostTakingNavigationAwayEndsGuidanceAtOnceAndANewRouteCanStart() {
        val asked = mutableListOf<String>()
        var answerStop: ((Any?) -> Unit)? = null
        CarLink.dartForTests = { method, _, done ->
            asked += method
            if (method == "stop") answerStop = done else done(null)
        }
        start()
        push("trip", trip("guiding", guiding))
        assertTrue(screens.top is NavigationScreen)
        // As the host does it: the library clears its own "navigating" flag, then calls the app's callback.
        nav.onStopNavigation()
        shadowOf(Looper.getMainLooper()).idle()
        // Over on the car before the phone has answered anything: the trip, the screen, the host.
        assertFalse(CarLink.trip.guiding)
        assertNull(CarLink.trip.step)
        assertNull(CarLink.trip.remainingS)
        assertEquals(CarLink.EMPTY_GEOJSON, CarLink.routeGeoJson)
        assertTrue(screens.top is HomeScreen)
        assertEquals(1, nav.navigationEndedCount)
        assertTrue("stop" in asked)
        // A trip the phone sent before it heard the stop does not start guidance again.
        push("trip", trip("guiding", guiding))
        assertFalse(CarLink.trip.guiding)
        assertEquals(1, nav.navigationStartedCount)
        assertTrue(screens.top is HomeScreen)
        // The phone has ended its guidance.
        push("trip", trip("browsing"))
        answerStop!!(null)
        // A new route, in the same car session: the preview has Start, and starting tells the host again.
        val screen = RoutePreviewScreen(car, CarMapRenderer(car), CarPlace("place:1", "Made Up Clinic", null, 42.5, -113.5, null))
        push("trip", trip("previewing"))
        assertEquals("Start", (templateOf(screen) as MapWithContentTemplate).actionStrip!!.actions[0].title.toString())
        push("trip", trip("guiding", guiding))
        assertTrue(CarLink.trip.guiding)
        assertEquals(2, nav.navigationStartedCount)
        assertTrue(screens.top is NavigationScreen)
    }

    // Car App Library 1.7.0: once the host has stopped navigation, the library's navigationEnded() sends nothing. If this
    // test's first half ever fails, the library changed and HostNavigation can go.
    @Test
    fun afterAHostStopNavigationEndedStillReachesTheHost() {
        var ended = 0
        val navHost = object : INavigationHost.Stub() {
            override fun navigationStarted() {}

            override fun navigationEnded() {
                ended++
            }

            override fun updateTrip(navState: Bundleable?) {}
        }
        val host = object : ICarHost.Stub() {
            override fun startCarApp(intent: Intent?) {}

            override fun getHost(type: String?): IBinder = navHost.asBinder()

            override fun finish() {}
        }
        val dispatcher = HostDispatcher()
        dispatcher.setCarHost(host)
        val m = TestNavigationManager(car, dispatcher)
        m.setNavigationManagerCallback(object : NavigationManagerCallback {})
        m.navigationStarted()
        m.onStopNavigation()
        m.navigationEnded()
        assertEquals(0, ended)
        assertTrue(HostNavigation.endAfterHostStop(m))
        assertEquals(1, ended)
    }

    @Test
    fun endRouteIsOverOnTheCarAtOnce() {
        val asked = mutableListOf<String>()
        CarLink.dartForTests = { method, _, _ -> asked += method }
        start()
        push("trip", trip("guiding", guiding))
        (screens.top as NavigationScreen).stop()
        // Before the phone answers (it never does in this test).
        assertFalse(CarLink.trip.guiding)
        assertTrue(screens.top is HomeScreen)
        assertEquals(1, nav.navigationEndedCount)
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue("stop" in asked)
    }

    // Bug: unplugging the car ended the route on the phone.
    @Test
    fun theCarGoingAwayInARealDriveLeavesThePhoneGuidingAndComingBackShowsGuidance() {
        val asked = mutableListOf<String>()
        CarLink.dartForTests = { method, _, done ->
            asked += method
            done(null)
        }
        val kept = mutableListOf<Boolean>()
        val c = start(session = CarSession(startEngine = {}, endEngine = { kept += it }))
        push("trip", trip("guiding", guiding))
        // As the library does it when the session is destroyed: its own stop first (the app's callback is posted), then the
        // session's teardown, then the callback.
        nav.onStopNavigation()
        c.moveToState(Lifecycle.State.DESTROYED)
        shadowOf(Looper.getMainLooper()).idle()
        assertFalse("stop" in asked)
        assertFalse(CarLink.carConnected)
        // The engine guidance runs in stays for the phone.
        assertEquals(listOf(true), kept)
        // The car connects again; the phone, still guiding, pushes its trip.
        car = TestCarContext.createCarContext(RuntimeEnvironment.getApplication())
        start()
        assertTrue(screens.top is HomeScreen)
        push("trip", trip("guiding", guiding))
        assertTrue(screens.top is NavigationScreen)
        assertEquals(1, nav.navigationStartedCount)
        assertEquals(1, nav.tripsSent.size)
    }

    @Test
    fun nothingIsKeptForATestDriveOrWithNoGuidance() {
        CarLink.dartForTests = { _, _, done -> done(null) }
        val kept = mutableListOf<Boolean>()
        // No guidance when the car leaves.
        start(session = CarSession(startEngine = {}, endEngine = { kept += it })).moveToState(Lifecycle.State.DESTROYED)
        // A test drive (the host switched it on): it ends with the car session.
        car = TestCarContext.createCarContext(RuntimeEnvironment.getApplication())
        val c = start(session = CarSession(startEngine = {}, endEngine = { kept += it }))
        nav.navigationManagerCallback!!.onAutoDriveEnabled()
        push("trip", trip("guiding", guiding))
        c.moveToState(Lifecycle.State.DESTROYED)
        assertEquals(listOf(false, false), kept)
    }

    // Bug: a navigation request delivered to the phone's activity threw in Flutter and went nowhere.
    @Test
    fun aNavigationRequestThatReachedThePhoneGoesToTheCarSession() {
        val asked = mutableListOf<Pair<String, Any?>>()
        CarLink.dartForTests = { method, args, done ->
            asked += method to args
            done(null)
        }
        start()
        assertTrue(NavIntent.fromPhone(Intent(CarContext.ACTION_NAVIGATE, Uri.parse("geo:0,0?q=Made+Up+Clinic&intent=directions"))))
        shadowOf(Looper.getMainLooper()).idle()
        val a = asked.single { it.first == "navigateTo" }.second as Map<*, *>
        assertEquals("Made Up Clinic", a["query"])
        assertEquals(false, a["start"])
        assertNull(a["lat"])
    }

    // Android Auto's own path: the request comes with the session's first screen, or to a session that is already up.
    @Test
    fun aNavigationRequestFromAndroidAutoIsAskedOfThePhoneAtStartAndLater() {
        val asked = mutableListOf<Pair<String, Any?>>()
        CarLink.dartForTests = { method, args, done ->
            asked += method to args
            done(null)
        }
        val session = CarSession(startEngine = {})
        start(Intent(CarContext.ACTION_NAVIGATE, Uri.parse("geo:42.5,-113.5")), session)
        shadowOf(Looper.getMainLooper()).idle()
        val first = asked.single { it.first == "navigateTo" }.second as Map<*, *>
        assertEquals(42.5, first["lat"])
        assertEquals(true, first["start"])
        asked.clear()
        session.onNewIntent(Intent(CarContext.ACTION_NAVIGATE, Uri.parse("geo:0,0?q=Made+Up+Clinic")))
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals("Made Up Clinic", (asked.single { it.first == "navigateTo" }.second as Map<*, *>)["query"])
    }

    // Bug: place rows showed the distance and never the address.
    @Test
    fun aPlaceRowShowsTheDistanceAndTheAddress() {
        val row = placeRow(CarPlace("place:1", "Made Up Clinic", "12 Nowhere Lane", 42.5, -113.5, 2400.0), imperial = true) {}
        val text = row.texts[0].toCharSequence() as android.text.Spanned
        assertEquals("  · 12 Nowhere Lane", text.toString())
        val spans = text.getSpans(0, text.length, androidx.car.app.model.DistanceSpan::class.java)
        assertEquals(1, spans.size)
        // The distance takes the place of the first character only; the address after it is text.
        assertEquals(0, text.getSpanStart(spans[0]))
        assertEquals(1, text.getSpanEnd(spans[0]))
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
                    done(listOf(place(1)))
                }, 2000)
            } else {
                done(null)
            }
        }
        val c = start()
        (screens.top as HomeScreen).openSaved()
        val saved = screens.top as SavedPlacesScreen
        assertTrue(savedList(saved).isLoading)
        shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(3))
        assertEquals(1, savedList(saved).singleList!!.items.size)
        assertEquals(1, asked.count { it == "saved" })
        // Dart says the saved places changed (or the core opened after the first ask): the list is asked for again.
        push("savedChanged", null)
        shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(3))
        assertEquals(2, asked.count { it == "saved" })
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

    @Test
    fun theGuidanceCardTakesTheThemesColorAndShowsTheNextStep() {
        start()
        val pal = mapOf(
            "day" to mapOf("theme" to "light", "route" to "#1f6fa8", "routeDriven" to "#9aa3ad", "badge" to "#ffffff", "badgeGlyph" to "#1a1d1f", "badgeEdge" to "#1f6fa8", "startDot" to "#7c8590", "destDot" to "#1a1d1f", "posFill" to "#ffffff", "posRing" to "#1f6fa8", "card" to "#fffdf8", "cardText" to "#1a1d1f", "cardSecondary" to "#55594f", "hatch" to "#1a1d1f", "miniBg" to "#f3ebd9", "miniBorder" to "#aca99b", "hostCard" to "#fffdf8"),
            "night" to mapOf("theme" to "tactical", "route" to "#ff5a4a", "routeDriven" to "#7a2a24", "badge" to "#ff8a7d", "badgeGlyph" to "#3a0b07", "badgeEdge" to "#000000", "startDot" to "#8e2b24", "destDot" to "#ff5a4a", "posFill" to "#ff9a90", "posRing" to "#ff5a4a", "card" to "#120404", "cardText" to "#e0473c", "cardSecondary" to "#8e2b24", "hatch" to "#e0473c", "miniBg" to "#000000", "miniBorder" to "#4a1612", "hostCard" to "#3a0b07"),
        )
        val then = mapOf("turn" to "right", "type" to "right", "cue" to "Turn right onto Road 2.", "road" to "Road 2", "distanceM" to 8000.0)
        push("trip", trip("guiding", guiding + mapOf("palette" to pal, "then" to then)))
        val t = templateOf(screens.top) as NavigationTemplate
        assertEquals(0xFF3A0B07.toInt(), t.backgroundColor!!.colorDark)
        assertEquals(0xFFFFFDF8.toInt(), t.backgroundColor!!.color)
        assertEquals("Turn right onto Road 2.", (t.navigationInfo as RoutingInfo).nextStep!!.cue.toString())
    }

    @Test
    fun routeOverviewShowsTheWholeRouteAndBackReturnsToGuidance() {
        start()
        val two = listOf(
            mapOf("index" to 0, "distanceM" to 24000.0, "durationS" to 1200, "via" to "Via Road 0"),
            mapOf("index" to 1, "distanceM" to 26000.0, "durationS" to 1300, "via" to "Via Road 9"),
        )
        push("trip", trip("guiding", guiding + mapOf("routes" to two)))
        val nav = screens.top as NavigationScreen
        // The overview button is the second one in the action strip.
        assertEquals(3, (templateOf(nav) as NavigationTemplate).actionStrip!!.actions.size)
        nav.openOverview()
        assertTrue(screens.top is RouteOverviewScreen)
        val t = templateOf(screens.top) as MapWithContentTemplate
        val list = (t.contentTemplate as ListTemplate)
        assertEquals(3, list.singleList!!.items.size)
        assertEquals(androidx.car.app.model.Action.TYPE_BACK, list.header!!.startHeaderAction!!.type)
        // A trip update while the overview is up does not throw it away.
        push("trip", trip("guiding", guiding + mapOf("routes" to two)))
        assertTrue(screens.top is RouteOverviewScreen)
        // Guidance ending takes the car back to the map.
        push("trip", trip("browsing"))
        assertTrue(screens.top is HomeScreen)
    }
}
