package com.happylittlellc.cache.car

import android.os.Handler
import android.os.Looper
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
 * The car's screens. Three steps at most from opening Cache to driving (saved places or search, the route, guidance), within the
 * Car App Library's limits. The words are short and never send the driver to the phone.
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

/** Saved places on the map, with Search. Opening Cache in the car starts here. */
class HomeScreen(carContext: CarContext, map: CarMapRenderer) : TripScreen(carContext, map) {
    private var places: List<CarPlace>? = null
    private val main = Handler(Looper.getMainLooper())
    private val retry = Runnable { load() }

    override fun onShown() = load()

    private fun load() {
        CarLink.call("saved") { r ->
            if (r == null && !CarLink.dartReady) {
                main.postDelayed(retry, 1000)
                return@call
            }
            places = CarPlace.list(r)
            android.util.Log.i("CacheCar", "saved places for the car: ${places?.size}")
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
        val header = Header.Builder().setTitle("Saved places").setStartHeaderAction(Action.APP_ICON).build()
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
            .setActionStrip(ActionStrip.Builder().addAction(Action.Builder().setIcon(CarIcons.search).setOnClickListener { search() }.build()).build())
            .setMapController(map.mapController())
            .build()
    }

    private fun open(p: CarPlace) = screenManager.push(RoutePreviewScreen(carContext, map, p))

    private fun search() = screenManager.push(SearchScreen(carContext, map))

    companion object {
        const val MAX_ROWS = 6
    }
}

/** Search for a place (by name, address or kind of place; by meaning when the phone's search model is loaded). */
class SearchScreen(carContext: CarContext, private val map: CarMapRenderer, private val initial: String? = null, preset: List<CarPlace>? = null) :
    Screen(carContext) {
    private var results: List<CarPlace>? = preset
    private var searching = false
    private var seq = 0
    private val main = Handler(Looper.getMainLooper())
    private var pending: Runnable? = null

    init {
        if (preset == null && !initial.isNullOrBlank()) find(initial)
    }

    private fun find(text: String) {
        val mine = ++seq
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

    override fun onGetTemplate(): Template {
        val b = SearchTemplate.Builder(object : SearchTemplate.SearchCallback {
            override fun onSearchTextChanged(searchText: String) {
                pending?.let { main.removeCallbacks(it) }
                val r = Runnable { find(searchText) }
                pending = r
                main.postDelayed(r, 600)
            }

            override fun onSearchSubmitted(searchText: String) {
                pending?.let { main.removeCallbacks(it) }
                find(searchText)
            }
        })
            .setHeaderAction(Action.BACK)
            .setSearchHint("Search for a place")
            .setShowKeyboardByDefault(results == null && initial == null)
        initial?.let { b.setInitialSearchText(it) }
        val list = results
        if (searching && list == null) {
            b.setLoading(true)
        } else {
            val items = ItemList.Builder()
            if (list != null) {
                items.setNoItemsMessage("No places found")
                for (p in list.take(MAX_ROWS)) items.addItem(placeRow(p, CarLink.trip.imperial) { screenManager.push(RoutePreviewScreen(carContext, map, p)) })
            }
            b.setItemList(items.build())
        }
        return b.build()
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

    // Redraw only when what this screen shows changed, not for every position update.
    override fun onTrip(trip: CarTrip) {
        val sig = listOf(trip.phase, trip.routing, trip.error, trip.routes, trip.routeIndex, trip.destinationName).toString()
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
                Action.Builder().setTitle("Start").setFlags(Action.FLAG_PRIMARY).setBackgroundColor(CarColor.GREEN).setOnClickListener {
                    started = true
                    CarLink.call("start")
                }.build(),
            )
        } else {
            strip.addAction(Action.Builder().setIcon(CarIcons.search).setOnClickListener { screenManager.push(SearchScreen(carContext, map)) }.build())
        }
        return MapWithContentTemplate.Builder()
            .setContentTemplate(content)
            .setActionStrip(strip.build())
            .setMapController(map.mapController())
            .build()
    }
}

/** Turn by turn: the phone's guidance, with Stop and the voice switch. */
class NavigationScreen(carContext: CarContext, map: CarMapRenderer) : TripScreen(carContext, map) {

    override fun onGetTemplate(): Template {
        val t = CarLink.trip
        val b = NavigationTemplate.Builder()
        val strip = ActionStrip.Builder()
            .addAction(Action.Builder().setTitle("Stop").setOnClickListener { stop() }.build())
            .addAction(
                Action.Builder().setIcon(if (t.voiceOn) CarIcons.voiceOn else CarIcons.voiceOff)
                    .setOnClickListener { CarLink.call("voice", mapOf("on" to !CarLink.trip.voiceOn)) }.build(),
            )
        b.setActionStrip(strip.build())
        b.setMapActionStrip(map.mapActionStrip())
        b.setPanModeListener { on -> map.panMode = on }
        when {
            t.arrived -> b.setNavigationInfo(MessageInfo.Builder("You have arrived").setText(t.destinationName ?: "").build())
            t.rerouting -> b.setNavigationInfo(MessageInfo.Builder("Finding a new route").build())
            else -> b.setNavigationInfo(CarModels.routingInfo(t) { CarIcons.maneuver(it) })
        }
        if (!t.arrived) CarModels.travelEstimate(t)?.let { b.setDestinationTravelEstimate(it) }
        return b.build()
    }

    private fun stop() {
        CarLink.call("stop")
    }
}
