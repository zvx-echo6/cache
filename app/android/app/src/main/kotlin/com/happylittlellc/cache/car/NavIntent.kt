package com.happylittlellc.cache.car

import android.content.Intent
import androidx.car.app.CarContext
import java.net.URLDecoder

/**
 * A navigation request (quality rule NF-6): `androidx.car.app.action.NAVIGATE` with a `geo:` address, as Gemini, the Google
 * Assistant and other apps send it ("geo:0,0?q=Googleplex", "geo:1.1,2.2?q=Starbucks&mode=w&intent=navigation").
 *
 * [start] is false for `intent=directions` (show the route without starting).
 */
data class NavRequest(val lat: Double?, val lon: Double?, val query: String?, val start: Boolean)

object NavIntent {
    private val coords = Regex("""^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*(?:\((.*)\))?\s*$""")

    fun parse(intent: Intent?): NavRequest? {
        if (intent == null || intent.action != CarContext.ACTION_NAVIGATE) return null
        return parse(intent.dataString ?: return null)
    }

    /**
     * A navigation request that reached the phone's activity instead of the car session (another app, or a test, starting the
     * activity directly). True when [intent] is one: the caller then keeps it away from Flutter. With a car connected it goes
     * to the car session, the same handling as a request Android Auto delivers; with none, or when it cannot be read, it is
     * dropped (the phone does not open places from "geo:" addresses).
     */
    fun fromPhone(intent: Intent?): Boolean {
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
        return NavRequest(lat, lon, name, start = params["intent"] != "directions")
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
