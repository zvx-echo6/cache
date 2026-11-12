package com.happylittlellc.cache.car

import android.os.Handler
import android.os.Looper
import androidx.activity.OnBackPressedCallback
import androidx.car.app.CarContext
import androidx.car.app.Screen
import androidx.car.app.model.Action
import androidx.car.app.model.ActionStrip
import androidx.car.app.model.CarColor
import androidx.car.app.model.CarText
import androidx.car.app.model.Header
import androidx.car.app.model.ItemList
import androidx.car.app.model.ListTemplate
import androidx.car.app.model.MessageTemplate
import androidx.car.app.model.Row
import androidx.car.app.model.SearchTemplate
import androidx.car.app.model.Template
import androidx.car.app.navigation.model.MapWithContentTemplate
import androidx.car.app.navigation.model.MessageInfo
import androidx.car.app.navigation.model.NavigationTemplate
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner

/**
 * The car's screens. Opening Cache shows the map with two buttons, Search and Saved places. From there to driving is three steps
 * at most (saved places or search, the route, guidance), so four screens with the map, within the Car App Library's limits.
 * Search reached from the saved places list is one screen more. The words are short and never send the driver to the phone.
 */

/** A screen that redraws when the trip changes, while it is on. */
abstract class TripScreen(carContext: CarContext, protected val map: CarMapRenderer) : Screen(carContext), CarLink.Listener {
    init {
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) {
                CarLink.addListener(this@TripScreen)
                // Recenter shows in the map buttons once the driver has moved the map.
                map.onFollowingChanged = { invalidate() }
                onShown()
            }

            override fun onStop(owner: LifecycleOwner) {
                CarLink.removeListener(this@TripScreen)
            }

            override fun onDestroy(owner: LifecycleOwner) {
                onGone()
            }
        })
    }

    open fun onShown() {}
    open fun onGone() {}

    override fun onTrip(trip: CarTrip) = invalidate()
}

/**
 * A screen that is shown over the guidance screen and goes back to it: the route overview, and the places to pick a stop from
 * (Add stop during a drive). While one is up, a trip update does not put the guidance screen back in front, and when guidance
 * ends it goes with the guidance screen.
 */
interface OverGuidance {
    val overGuidance: Boolean
}

internal fun isOverGuidance(s: Screen): Boolean = s is OverGuidance && s.overGuidance

/** The screen Add stop returns to once a stop is picked: the route screen (before Start) or the guidance screen. */
internal const val STOP_RETURN = "cache.add-stop.return"

/** Add stop: the place joins the route (the phone works out the new route), and the car goes back to the screen Add stop was
 * opened from. When the phone says no (it tells why in a notice), the list stays for another choice. */
internal fun addStop(screen: Screen, p: CarPlace) {
    CarLink.call("addStop", mapOf("id" to p.id)) { r ->
        if (r == true) screen.screenManager.popTo(STOP_RETURN)
    }
}

internal fun placeRow(p: CarPlace, imperial: Boolean, onClick: () -> Unit): Row {
    val b = Row.Builder().setTitle(p.name).setOnClickListener(onClick)
    val dist = CarModels.placeDistance(p.distanceM, imperial)
    val addr = p.address
    when {
        dist != null && addr != null -> b.addText(combine(dist, addr))
        dist != null -> b.addText(dist)
        addr != null -> b.addText(addr)
    }
    return b.build()
}

private fun combine(dist: CharSequence, addr: String): CharSequence {
    val s = android.text.SpannableStringBuilder(dist)
    s.append(" · ").append(addr)
    return s
}

/** The whole map, with two buttons: Search and Saved places. Opening Cache in the car starts here. */
class HomeScreen(carContext: CarContext, map: CarMapRenderer) : TripScreen(carContext, map) {
    // Nothing here changes with the trip (the map buttons redraw through the renderer's own callback).
    override fun onTrip(trip: CarTrip) {}

    override fun onGetTemplate(): Template =
        NavigationTemplate.Builder()
            .setActionStrip(
                ActionStrip.Builder()
                    .addAction(Action.Builder().setIcon(CarIcons.search).setFlags(Action.FLAG_IS_PERSISTENT).setOnClickListener { openSearch() }.build())
                    .addAction(Action.Builder().setIcon(CarIcons.saved).setFlags(Action.FLAG_IS_PERSISTENT).setOnClickListener { openSaved() }.build())
                    .build(),
            )
            .setMapActionStrip(map.mapActionStrip())
            .setPanModeListener { on -> map.panMode = on }
            .build()

    internal fun openSearch() = screenManager.push(SearchScreen(carContext, map))

    internal fun openSaved() = screenManager.push(SavedPlacesScreen(carContext, map))
}

/** Saved places in a list over the map, with Search. Back closes it. With [forStop] the place picked becomes a stop on the
 * route (Add stop) instead of a destination. */
class SavedPlacesScreen(carContext: CarContext, map: CarMapRenderer, private val forStop: Boolean = false) : TripScreen(carContext, map), OverGuidance {
    override val overGuidance: Boolean = forStop && CarLink.trip.guiding
    private var places: List<CarPlace>? = null
    private val main = Handler(Looper.getMainLooper())
    private val retry = Runnable { load() }

    override fun onShown() = load()

    // The phone's saved places changed, or the core opened after the first ask (the car started the app): ask again.
    override fun onSavedChanged() = load()

    private fun load() {
        CarLink.call("saved") { r ->
            if (r == null && !CarLink.dartReady) {
                main.postDelayed(retry, 1000)
                return@call
            }
            places = CarPlace.list(r)
            android.util.Log.i("CacheCar", "saved places for the car: ${places?.size} (answer ${if (r == null) "none" else "given"})")
            invalidate()
        }
    }

    override fun onGone() {
        main.removeCallbacks(retry)
    }

    private var shownImperial: Boolean? = null

    // The saved places list does not change with every position update; only the units its distances are in can (the first trip
    // the phone pushes says which).
    override fun onTrip(trip: CarTrip) {
        if (shownImperial == trip.imperial) return
        shownImperial = trip.imperial
        invalidate()
    }

    override fun onGetTemplate(): Template {
        val header = Header.Builder().setTitle(if (forStop) "Add stop" else "Saved places").setStartHeaderAction(Action.BACK).build()
        val content = ListTemplate.Builder().setHeader(header)
        val list = places
        if (list == null) {
            content.setLoading(true)
        } else {
            val items = ItemList.Builder().setNoItemsMessage("No saved places yet. Search for a place to go.")
            for (p in list.take(MAX_ROWS)) items.addItem(placeRow(p, CarLink.trip.imperial) { open(p) })
            content.setSingleList(items.build())
        }
        return MapWithContentTemplate.Builder()
            .setContentTemplate(content.build())
            .setActionStrip(ActionStrip.Builder().addAction(Action.Builder().setIcon(CarIcons.search).setFlags(Action.FLAG_IS_PERSISTENT).setOnClickListener { search() }.build()).build())
            .setMapController(map.mapController())
            .build()
    }

    internal fun open(p: CarPlace) {
        if (forStop) addStop(this, p) else screenManager.push(RoutePreviewScreen(carContext, map, p))
    }

    internal fun search() = screenManager.push(SearchScreen(carContext, map, forStop = forStop))

    companion object {
        const val MAX_ROWS = 6
    }
}

/**
 * Search for a place (by name, address or kind of place; by meaning when the phone's search model is loaded). While the box is
 * empty it lists the saved places, unless it was opened with text or with places already found.
 */
class SearchScreen(
    carContext: CarContext,
    private val map: CarMapRenderer,
    private val initial: String? = null,
    preset: List<CarPlace>? = null,
    private val forStop: Boolean = false,
) : Screen(carContext), OverGuidance {
    // With forStop the place picked becomes a stop on the route (Add stop) instead of a destination.
    override val overGuidance: Boolean = forStop && CarLink.trip.guiding

    private var results: List<CarPlace>? = preset
    private var searching = false

    // The text the results are for (what was last searched: typed, submitted, or the text the screen was opened with). The
    // template puts it in the box, so when the screen is shown again (Back from a route) the box and the list still agree.
    private var query: String = initial.orEmpty()
    private var seq = 0
    private val main = Handler(Looper.getMainLooper())
    private var pending: Runnable? = null

    // The saved places, listed while the box is empty. They are kept apart from the results, and shown only when there are no
    // results and no search is running, so an answer that comes late never replaces what was found for typed text.
    private val offersSaved = preset == null && initial.isNullOrBlank()
    private var saved: List<CarPlace> = emptyList()

    init {
        if (preset == null && !initial.isNullOrBlank()) find(initial)
        if (offersSaved) {
            CarLink.call("saved") { r ->
                saved = CarPlace.list(r)
                if (results == null && !searching) invalidate()
            }
        }
    }

    private fun find(text: String) {
        val mine = ++seq
        query = text
        if (text.isBlank()) {
            results = null
            searching = false
            invalidate()
            return
        }
        searching = true
        invalidate()
        CarLink.call("search", mapOf("query" to text)) { r ->
            if (mine != seq) return@call
            searching = false
            results = CarPlace.list(r)
            invalidate()
        }
    }

    internal fun textChanged(searchText: String) {
        pending?.let { main.removeCallbacks(it) }
        pending = null
        // The box holds what the list is already for (the host says so when it shows the screen again with its text): nothing
        // to look up.
        if (searchText == query && !searching && (results != null || searchText.isBlank())) return
        val r = Runnable { find(searchText) }
        pending = r
        main.postDelayed(r, 600)
    }

    internal fun submitted(searchText: String) {
        pending?.let { main.removeCallbacks(it) }
        find(searchText)
    }

    override fun onGetTemplate(): Template {
        val b = SearchTemplate.Builder(object : SearchTemplate.SearchCallback {
            override fun onSearchTextChanged(searchText: String) = textChanged(searchText)

            override fun onSearchSubmitted(searchText: String) = submitted(searchText)
        })
            .setHeaderAction(Action.BACK)
            .setSearchHint("Search for a place")
            .setShowKeyboardByDefault(results == null && initial == null)
        if (query.isNotEmpty()) b.setInitialSearchText(query)
        val list = results
        if (searching && list == null) {
            b.setLoading(true)
        } else {
            val items = ItemList.Builder()
            if (list != null) {
                items.setNoItemsMessage("No places found")
                for (p in list.take(MAX_ROWS)) items.addItem(placeRow(p, CarLink.trip.imperial) { open(p) })
            } else if (offersSaved) {
                // The box is empty: the saved places (none, and the list is empty as before).
                for (p in saved.take(MAX_ROWS)) items.addItem(placeRow(p, CarLink.trip.imperial) { open(p) })
            }
            b.setItemList(items.build())
        }
        return b.build()
    }

    internal fun open(p: CarPlace) {
        if (forStop) addStop(this, p) else screenManager.push(RoutePreviewScreen(carContext, map, p))
    }

    companion object {
        const val MAX_ROWS = 6
    }
}

/** The routes to a place: pick one, then Start. */
class RoutePreviewScreen(carContext: CarContext, map: CarMapRenderer, private val place: CarPlace) : TripScreen(carContext, map) {
    private var asked = false
    private var started = false
    private var shownSig: String? = null

    init {
        marker = STOP_RETURN
    }

    // Redraw only when what this screen shows changed, not for every position update.
    override fun onTrip(trip: CarTrip) {
        val sig = listOf(trip.phase, trip.routing, trip.error, trip.routes, trip.routeIndex, trip.destinationName, trip.stops).toString()
        if (sig == shownSig) return
        shownSig = sig
        invalidate()
    }

    override fun onShown() {
        if (asked) return
        asked = true
        CarLink.call("directions", mapOf("id" to place.id)) { invalidate() }
    }

    override fun onGone() {
        if (!started) CarLink.call("cancel")
    }

    override fun onGetTemplate(): Template {
        val t = CarLink.trip
        val header = Header.Builder().setTitle(t.destinationName ?: place.name).setStartHeaderAction(Action.BACK).build()
        val ready = t.previewing && !t.routing && t.routes.isNotEmpty()
        val content: Template = when {
            t.previewing && !t.routing && t.error != null ->
                MessageTemplate.Builder(t.error).setHeader(header).build()
            !ready -> ListTemplate.Builder().setHeader(header).setLoading(true).build()
            else -> {
                val items = ItemList.Builder()
                for (r in t.routes) {
                    val row = Row.Builder().setTitle(CarText.create(CarModels.routeTitle(r, t.imperial)))
                    r.via?.let { row.addText(it) }
                    // The stops on the way, named as the phone's route panel names them.
                    if (t.stops.isNotEmpty()) row.addText(t.stops.withIndex().joinToString(" · ") { (i, s) -> "Stop ${i + 1}: ${s.name}" })
                    items.addItem(row.build())
                }
                items.setOnSelectedListener { i -> CarLink.call("selectRoute", mapOf("index" to i)) }
                items.setSelectedIndex(t.routeIndex.coerceIn(0, t.routes.size - 1))
                ListTemplate.Builder().setHeader(header).setSingleList(items.build()).build()
            }
        }
        val strip = ActionStrip.Builder()
        if (ready) {
            strip.addAction(
                Action.Builder().setTitle("Start").setFlags(Action.FLAG_PRIMARY or Action.FLAG_IS_PERSISTENT).setBackgroundColor(CarColor.GREEN).setOnClickListener {
                    started = true
                    CarLink.call("start")
                }.build(),
            )
            // Add stop, beside Start: a place from Saved places (or its Search) joins this route.
            strip.addAction(Action.Builder().setTitle("Add stop").setOnClickListener { addStop() }.build())
        } else {
            strip.addAction(Action.Builder().setIcon(CarIcons.search).setOnClickListener { screenManager.push(SearchScreen(carContext, map)) }.build())
        }
        return MapWithContentTemplate.Builder()
            .setContentTemplate(content)
            .setActionStrip(strip.build())
            .setMapController(map.mapController())
            .build()
    }

    internal fun addStop() = screenManager.push(SavedPlacesScreen(carContext, map, forStop = true))
}

/** Turn by turn: the phone's guidance, with End route, Route overview and the voice switch. */
class NavigationScreen(carContext: CarContext, map: CarMapRenderer) : TripScreen(carContext, map) {
    init {
        // The car's Back key while guiding. Left to the library it popped this screen: the home screen showed (its Search and
        // Saved places buttons, no turn card, no arrival card, the map's free area changed under the overlay) until the next
        // trip update, up to a second later, when the session pushed a new guidance screen. Guidance is left with End route,
        // so Back does nothing here while the trip is guiding. The callback is this screen's: it holds only while the screen
        // is the one showing, so Back on the route overview still closes the overview.
        marker = STOP_RETURN
        carContext.onBackPressedDispatcher.addCallback(
            this,
            object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    if (!CarLink.trip.guiding) screenManager.pop()
                }
            },
        )
    }

    override fun onGetTemplate(): Template {
        val t = CarLink.trip
        val b = NavigationTemplate.Builder()
        val strip = ActionStrip.Builder()
            .addAction(Action.Builder().setTitle("End route").setOnClickListener { stop() }.build())
            .addAction(Action.Builder().setIcon(CarIcons.overview).setOnClickListener { openOverview() }.build())
            .addAction(
                Action.Builder().setIcon(if (t.voiceOn) CarIcons.voiceOn else CarIcons.voiceOff)
                    .setOnClickListener { CarLink.call("voice", mapOf("on" to !CarLink.trip.voiceOn)) }.build(),
            )
        // Add stop (the strip's fourth and last place): Saved places to pick from, with Search behind its button. Typing may
        // be blocked by the car while it moves; the saved places list is not.
        if (!t.arrived) strip.addAction(Action.Builder().setIcon(CarIcons.addStop).setOnClickListener { addStop() }.build())
        b.setActionStrip(strip.build())
        b.setMapActionStrip(map.mapActionStrip())
        b.setPanModeListener { on -> map.panMode = on }
        // The host's own guidance card in the theme's color (the host may override it for contrast).
        CarModels.hostBackground(t)?.let { b.setBackgroundColor(it) }
        when {
            t.arrived -> b.setNavigationInfo(MessageInfo.Builder("You have arrived").setText(t.destinationName ?: "").build())
            t.rerouting -> b.setNavigationInfo(MessageInfo.Builder("Finding a new route").build())
            else -> b.setNavigationInfo(CarModels.routingInfo(t) { CarIcons.maneuver(it) })
        }
        if (!t.arrived) CarModels.travelEstimate(t)?.let { b.setDestinationTravelEstimate(it) }
        return b.build()
    }

    // End route: over on the car at once, and the phone is asked to end its guidance.
    internal fun stop() = CarLink.stopGuidance()

    internal fun openOverview() = screenManager.push(RouteOverviewScreen(carContext, map))

    internal fun addStop() = screenManager.push(SavedPlacesScreen(carContext, map, forStop = true))
}

/**
 * The whole route on the map, with what is left and the routes there are (information only: the route is chosen before the
 * drive). Back returns to guidance. Not RoutePreviewNavigationTemplate: its rows are routes to pick and a Navigate button, which
 * is for before the drive; this is a map with a list, as the Car App Library's MapWithContentTemplate is meant for.
 */
class RouteOverviewScreen(carContext: CarContext, map: CarMapRenderer) : TripScreen(carContext, map), OverGuidance {
    override val overGuidance: Boolean = true
    private var shownSig: String? = null

    override fun onShown() = map.setOverview(true)

    override fun onGone() = map.setOverview(false)

    // The summary changes with the minute, not with every position update.
    override fun onTrip(trip: CarTrip) {
        val sig = listOf(trip.remainingS?.div(30), trip.routes, trip.routeIndex, trip.destinationName, trip.imperial, trip.stops).toString()
        if (sig == shownSig) return
        shownSig = sig
        invalidate()
    }

    override fun onGetTemplate(): Template {
        val t = CarLink.trip
        val header = Header.Builder().setTitle("Route overview").setStartHeaderAction(Action.BACK).build()
        val items = ItemList.Builder()
        // The stops still ahead, in order, then the destination. The list holds six rows: the destination and the routes keep
        // theirs, the stops take what is left.
        val routeRows = if (t.routes.size > 1) t.routes.size else 0
        for ((i, s) in t.stops.withIndex().take((SavedPlacesScreen.MAX_ROWS - 1 - routeRows).coerceAtLeast(0))) {
            val row = Row.Builder().setTitle("Stop ${i + 1}: ${s.name}")
            s.address?.let { row.addText(it) }
            items.addItem(row.build())
        }
        val left = Row.Builder().setTitle(t.destinationName ?: "Destination")
        CarModels.leftText(t)?.let { left.addText(it) }
        t.destinationAddress?.let { left.addText(it) }
        items.addItem(left.build())
        if (t.routes.size > 1) {
            for (r in t.routes) {
                val row = Row.Builder().setTitle(CarText.create(CarModels.routeTitle(r, t.imperial)))
                row.addText(if (r.index == t.routeIndex) "Your route" else "Other route")
                r.via?.let { row.addText(it) }
                items.addItem(row.build())
            }
        }
        return MapWithContentTemplate.Builder()
            .setContentTemplate(ListTemplate.Builder().setHeader(header).setSingleList(items.build()).build())
            .setMapController(map.mapController())
            .build()
    }
}
