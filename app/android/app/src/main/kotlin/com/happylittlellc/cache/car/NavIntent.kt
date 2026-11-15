package com.happylittlellc.cache.car

import android.content.Intent
import androidx.car.app.CarContext
import java.net.URLDecoder

/**
 * A navigation request (quality rule NF-6): `androidx.car.app.action.NAVIGATE` with a `geo:` address, as Gemini, the Google
 * Assistant and other apps send it ("geo:0,0?q=Googleplex", "geo:1.1,2.2?q=Starbucks&mode=w&intent=navigation").
 *
 * [kind] is the request's `intent` value ([NavKind]); [start] is false for `intent=directions` (show the route without starting).
 */
data class NavRequest(val lat: Double?, val lon: Double?, val query: String?, val kind: NavKind = NavKind.NAVIGATION) {
    val start: Boolean get() = kind != NavKind.DIRECTIONS
    val addStop: Boolean get() = kind == NavKind.ADD_A_STOP
}

/**
 * The `intent` value of a navigation request, as Google's "Implement navigation app intents" page lists them: `navigation` (the
 * default: replace the destination and start), `add_a_stop` (add the place as the next stop, keeping the destinations there are)
 * and `directions` (show the route without starting). A machine format: the values are matched as they are. A missing or unknown
 * value is [NAVIGATION], the page's default.
 */
enum class NavKind(val value: String) {
    NAVIGATION("navigation"),
    ADD_A_STOP("add_a_stop"),
    DIRECTIONS("directions");

    companion object {
        fun of(value: String?): NavKind = entries.firstOrNull { it.value == value } ?: NAVIGATION
    }
}

/**
 * A custom action from Gemini or the Google Assistant: `android.intent.action.VIEW` with `geo.action:?act=<code>` (Google's
 * "Implement navigation app intents" page). The assistant does the understanding; the code is a fixed machine value, matched as
 * it is.
 *
 * [Answer] is a question about the trip, said aloud by the phone's voice ([Answer.kind] is what Dart composes the words from:
 * `eta`, `distance`, `turn`, `destination`). [Unsupported] is any other code, or none: the car tells the driver so.
 */
sealed interface CarAction {
    object ExitNavigation : CarAction
    object Mute : CarAction
    object Unmute : CarAction
    object RouteOverview : CarAction
    data class Answer(val kind: String) : CarAction
    data class Unsupported(val act: String?) : CarAction

    companion object {
        /** The action a code stands for. */
        fun of(act: String?): CarAction = when (act) {
            "exit_navigation" -> ExitNavigation
            "mute" -> Mute
            "unmute" -> Unmute
            "route_overview" -> RouteOverview
            "eta", "time_to_destination" -> Answer("eta")
            "distance_to_destination" -> Answer("distance")
            "query_next_turn", "distance_to_next_turn", "time_to_next_turn" -> Answer("turn")
            "query_destination" -> Answer("destination")
            else -> Unsupported(act)
        }
    }
}

/**
 * A `geo:` link opened with `android.intent.action.VIEW`: what Gemini and the Google Assistant send for a voice search ("find gas
 * near me" is `geo:0,0?q=gas+station`), and what any app sends to the "Open with" list for a map link. The assistant does the
 * understanding; only the machine format is read.
 *
 * [Search] is a `q` (with or without coordinates, which only say where the link was meant): the car lists the places found.
 * [Point] is coordinates with no search: the route to it is shown, not started (NAVIGATE's `intent=directions`).
 */
sealed interface GeoView {
    data class Search(val lat: Double?, val lon: Double?, val query: String) : GeoView
    data class Point(val req: NavRequest) : GeoView
}

object NavIntent {
    private val coords = Regex("""^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*(?:\((.*)\))?\s*$""")

    fun parse(intent: Intent?): NavRequest? {
        if (intent == null || intent.action != CarContext.ACTION_NAVIGATE) return null
        return parse(intent.dataString ?: return null)
    }

    /** True when [intent] is a `VIEW` of a `geo:` address (a voice search, or a map link picked from "Open with"). */
    fun isGeoView(intent: Intent?): Boolean {
        if (intent == null || intent.action != Intent.ACTION_VIEW) return false
        val scheme = intent.data?.scheme?.lowercase() ?: return false
        return scheme == "geo" || scheme == "geo.offline"
    }

    /** The search or point [intent] (a `VIEW` of a `geo:` address) asks for, or null when it is not one or carries neither. */
    fun parseView(intent: Intent?): GeoView? {
        if (!isGeoView(intent)) return null
        return parseView(intent!!.dataString ?: return null)
    }

    fun parseView(uri: String): GeoView? {
        val req = parse(uri) ?: return null
        val q = uri.indexOf('?')
        val raw = if (q < 0) null else query(uri.substring(q + 1))["q"]?.trim()
        // "q=42.5,-113.5(Burley)" is a labelled point, not words to search for.
        val labelled = raw != null && coords.matches(raw)
        if (req.query != null && !labelled) return GeoView.Search(req.lat, req.lon, req.query)
        if (req.lat != null && req.lon != null) return GeoView.Point(NavRequest(req.lat, req.lon, req.query, NavKind.DIRECTIONS))
        return null
    }

    /** The custom action [intent] carries (`VIEW` with a `geo.action:` address), or null when it is not one. */
    fun parseAction(intent: Intent?): CarAction? {
        if (intent == null || intent.action != Intent.ACTION_VIEW) return null
        return parseAction(intent.dataString ?: return null)
    }

    fun parseAction(uri: String): CarAction? {
        val colon = uri.indexOf(':')
        if (colon < 0 || uri.substring(0, colon).lowercase() != "geo.action") return null
        val q = uri.indexOf('?')
        val act = if (q < 0) null else query(uri.substring(q + 1))["act"]?.trim()?.takeIf { it.isNotEmpty() }
        return CarAction.of(act)
    }

    /**
     * A navigation request that reached the phone's activity instead of the car session (another app, or a test, starting the
     * activity directly). True when [intent] is one: the caller then keeps it away from Flutter. With a car connected it goes
     * to the car session, the same handling as a request Android Auto delivers; with none, or when it cannot be read, it is
     * dropped (the phone does not open places from "geo:" addresses).
     *
     * A `VIEW` of a `geo:` address (a voice search, or Cache picked from "Open with") goes the same way, except that with no
     * car it is not dropped: [onPhone] gets it, to open the phone's Maps tab with the search or the point.
     */
    fun fromPhone(intent: Intent?, onPhone: (GeoView) -> Unit = {}): Boolean {
        // A custom action ("geo.action:") goes the same way: to the car session when a car is connected, otherwise dropped.
        parseAction(intent)?.let {
            CarLink.carAction(it)
            return true
        }
        if (isGeoView(intent)) {
            parseView(intent)?.let { v ->
                val taken = when (v) {
                    is GeoView.Search -> CarLink.searchRequest(v)
                    is GeoView.Point -> CarLink.navRequest(v.req)
                }
                if (!taken) onPhone(v)
            }
            return true
        }
        if (intent == null || intent.action != CarContext.ACTION_NAVIGATE) return false
        parse(intent)?.let { CarLink.navRequest(it) }
        return true
    }

    /** [intent] with the request taken out: what the launcher sends, for the activity to start on. */
    fun plainLaunch(intent: Intent): Intent = Intent(intent).setAction(Intent.ACTION_MAIN).setData(null)

    fun parse(uri: String): NavRequest? {
        val colon = uri.indexOf(':')
        if (colon < 0) return null
        val scheme = uri.substring(0, colon).lowercase()
        if (scheme != "geo" && scheme != "geo.offline") return null
        val rest = uri.substring(colon + 1).removePrefix("//")
        val q = rest.indexOf('?')
        val where = if (q < 0) rest else rest.substring(0, q)
        val params = if (q < 0) emptyMap() else query(rest.substring(q + 1))
        var lat: Double? = null
        var lon: Double? = null
        coords.find(decode(where))?.let { m ->
            lat = m.groupValues[1].toDoubleOrNull()
            lon = m.groupValues[2].toDoubleOrNull()
        }
        if (lat == 0.0 && lon == 0.0) {
            lat = null
            lon = null
        }
        var name = params["q"]?.trim()?.takeIf { it.isNotEmpty() }
        // "q=42.53,-113.79(Burley)": coordinates with a label.
        name?.let { n ->
            coords.find(n)?.let { m ->
                if (lat == null) {
                    lat = m.groupValues[1].toDoubleOrNull()
                    lon = m.groupValues[2].toDoubleOrNull()
                }
                name = m.groupValues[3].trim().takeIf { it.isNotEmpty() }
            }
        }
        if (lat == null && name == null) return null
        return NavRequest(lat, lon, name, NavKind.of(params["intent"]))
    }

    private fun query(s: String): Map<String, String> = s.split('&').mapNotNull { part ->
        val eq = part.indexOf('=')
        if (eq <= 0) null else decode(part.substring(0, eq)) to decode(part.substring(eq + 1))
    }.toMap()

    private fun decode(s: String): String = try {
        URLDecoder.decode(s, "UTF-8")
    } catch (e: IllegalArgumentException) {
        s
    }
}
