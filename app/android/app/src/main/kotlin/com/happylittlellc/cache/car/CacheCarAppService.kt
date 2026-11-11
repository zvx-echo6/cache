package com.happylittlellc.cache.car

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.res.Configuration
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.car.app.CarAppService
import androidx.car.app.CarToast
import androidx.car.app.Screen
import androidx.car.app.ScreenManager
import androidx.car.app.Session
import androidx.car.app.SessionInfo
import androidx.car.app.AppManager
import androidx.car.app.navigation.NavigationManager
import androidx.car.app.navigation.NavigationManagerCallback
import androidx.car.app.validation.HostValidator
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner

/**
 * Cache in Android Auto: a navigation app (category `androidx.car.app.category.NAVIGATION`). The car shows the phone's own
 * guidance; see [CarLink] and lib/car/car_bridge.dart.
 */
class CacheCarAppService : CarAppService() {
    override fun createHostValidator(): HostValidator =
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            HostValidator.ALLOW_ALL_HOSTS_VALIDATOR
        } else {
            HostValidator.Builder(applicationContext).addAllowedHosts(androidx.car.app.R.array.hosts_allowlist_sample).build()
        }

    override fun onCreateSession(sessionInfo: SessionInfo): Session = CarSession()
}

/**
 * One car screen. It starts (or joins) the app's Flutter engine, draws the map ([CarMapRenderer]), tells the host when guidance
 * starts and ends and what the trip is ([NavigationManager]), posts the turn-by-turn notification, and holds navigation audio
 * focus for the prompts.
 *
 * [startEngine] is the shared engine; the tests give a stand-in.
 */
class CarSession(
    private val startEngine: (Context) -> Unit = { SharedEngine.obtain(it) },
    private val endEngine: (keep: Boolean) -> Unit = { SharedEngine.carEnded(it) },
) : Session(), CarLink.Listener {
    private val main = Handler(Looper.getMainLooper())
    private var ready = false
    private var navigating = false
    private var autoDrive = false
    lateinit var renderer: CarMapRenderer
        private set
    private var navigation: NavigationManager? = null
    private var notifications: CarNotifications? = null
    private var audio: CarAudio? = null
    private val screenManager: ScreenManager get() = carContext.getCarService(ScreenManager::class.java)

    init {
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onDestroy(owner: LifecycleOwner) = tearDown()
        })
    }

    private fun setUp() {
        if (ready) return
        ready = true
        try {
            startEngine(carContext)
        } catch (e: Exception) {
            Log.w(TAG, "the app engine could not start", e)
        }
        SharedEngine.carStarted()
        renderer = CarMapRenderer(carContext)
        carContext.getCarService(AppManager::class.java).setSurfaceCallback(renderer)
        notifications = try {
            CarNotifications(carContext)
        } catch (e: Exception) {
            null
        }
        audio = CarAudio(carContext).also { CarLink.audio = it }
        val nav = carContext.getCarService(NavigationManager::class.java)
        navigation = nav
        nav.setNavigationManagerCallback(object : NavigationManagerCallback {
            // The host stops Cache's guidance (another navigation app started, or the car asked): no more turns, notifications or
            // voice from Cache, at once.
            //
            // The Car App Library also calls this when the session is destroyed (NavigationManager's own lifecycle observer;
            // the callback is posted, so it runs after tearDown). That is the car going away, not another navigation source:
            // the phone keeps guiding, and tearDown has already ended everything on the car side.
            override fun onStopNavigation() {
                if (!ready) return
                if (navigating) {
                    navigating = false
                    try {
                        navigation?.navigationEnded()
                    } catch (e: Exception) {
                        Log.w(TAG, "navigationEnded", e)
                    }
                }
                notifications?.cancel()
                audio?.release()
                CarLink.call("stop")
            }

            // Google Play's review: the next guidance is a simulated drive along the route.
            override fun onAutoDriveEnabled() {
                autoDrive = true
                CarLink.call("autoDrive", mapOf("on" to true))
            }
        })
        CarLink.addListener(this)
        CarLink.setCarConnected(true)
        // The position keeps coming with the phone locked and the phone app closed (the normal way to use Android Auto).
        CarLocationService.start(carContext)
    }

    override fun onCreateScreen(intent: Intent): Screen {
        setUp()
        val home = HomeScreen(carContext, renderer)
        // A navigation request that opened Cache: handled once the first screen is up.
        NavIntent.parse(intent)?.let { req -> main.post { handle(req) } }
        return home
    }

    override fun onNewIntent(intent: Intent) {
        NavIntent.parse(intent)?.let { handle(it) }
    }

    // A navigation request that reached the phone's activity while this car is connected: handled as the car's own are.
    override fun onNavRequest(req: NavRequest) = handle(req)

    override fun onCarConfigurationChanged(newConfiguration: Configuration) {
        if (ready) renderer.setDark(carContext.isDarkMode)
    }

    /** A navigation request (NF-6): coordinates or a saved place's name start guidance; any other name lists the places found. */
    private fun handle(req: NavRequest) {
        CarLink.call("navigateTo", mapOf("lat" to req.lat, "lon" to req.lon, "query" to req.query, "start" to req.start)) { r ->
            val res = r.asMap() ?: return@call
            val places = res["places"]
            if (places != null) {
                val sm = screenManager
                sm.popToRoot()
                sm.push(SearchScreen(carContext, renderer, req.query, CarPlace.list(places)))
            } else if (res["started"] != true) {
                val id = res["id"] as? String ?: return@call
                val t = CarLink.trip
                screenManager.push(RoutePreviewScreen(carContext, renderer, CarPlace(id, t.destinationName ?: req.query ?: "", t.destinationAddress, t.destinationLat ?: 0.0, t.destinationLon ?: 0.0, null)))
            }
        }
    }

    override fun onDartReady() {
        if (autoDrive) CarLink.call("autoDrive", mapOf("on" to true))
    }

    override fun onTrip(trip: CarTrip) {
        val nav = navigation ?: return
        if (trip.guiding) {
            if (!navigating) {
                try {
                    nav.navigationStarted()
                    navigating = true
                } catch (e: Exception) {
                    Log.w(TAG, "navigationStarted", e)
                }
            }
            if (navigating) {
                try {
                    nav.updateTrip(CarModels.trip(trip, { CarIcons.maneuver(it) }))
                } catch (e: Exception) {
                    Log.w(TAG, "updateTrip", e)
                }
                notifications?.show(trip)
            }
            if (screenManager.top !is NavigationScreen && screenManager.top !is RouteOverviewScreen) {
                screenManager.popToRoot()
                screenManager.push(NavigationScreen(carContext, renderer))
            }
        } else {
            if (navigating) {
                navigating = false
                try {
                    nav.navigationEnded()
                } catch (e: Exception) {
                    Log.w(TAG, "navigationEnded", e)
                }
            }
            notifications?.cancel()
            if (screenManager.top is NavigationScreen || screenManager.top is RouteOverviewScreen) screenManager.popToRoot()
        }
    }

    override fun onNotice(text: String) {
        CarToast.makeText(carContext, text, CarToast.LENGTH_LONG).show()
    }

    private fun tearDown() {
        if (!ready) return
        ready = false
        // The car went away during a real drive: the phone keeps guiding (the car side never asks it to stop here), so the
        // app's engine, where guidance runs, must stay even with no phone screen open. When the car connects again the phone
        // pushes its trip and onTrip shows guidance and tells the host it started. A simulated test drive is the deliberate
        // exception: it exists only for the car's review, so the phone ends it when the car leaves (lib/car/car_bridge.dart)
        // and nothing is kept for it.
        val keepEngine = CarLink.trip.guiding && !autoDrive
        CarLink.removeListener(this)
        CarLink.setCarConnected(false)
        if (navigating) {
            navigating = false
            try {
                navigation?.navigationEnded()
            } catch (e: Exception) {
                Log.w(TAG, "navigationEnded", e)
            }
        }
        notifications?.cancel()
        audio?.release()
        CarLink.audio = null
        renderer.release()
        CarLocationService.stop(carContext)
        endEngine(keepEngine)
    }

    companion object {
        private const val TAG = "CacheCar"
    }
}
