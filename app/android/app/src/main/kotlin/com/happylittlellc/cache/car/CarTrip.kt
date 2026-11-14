package com.happylittlellc.cache.car

/**
 * The trip as Dart pushed it (lib/car/car_trip.dart): the phone's guidance, read only. Numbers are meters and seconds; the
 * turn is the phone's TurnIcon name.
 */
data class CarStep(
    val turn: String,
    val type: String,
    val cue: String,
    val road: String?,
    val distanceM: Double,
)

/** A stop still ahead on the route (the phone's Add stop, or the car's). [number] is the one the turn card says when the stop
 * is reached: its place in the route as it was made, kept when the stops before it are passed. */
data class CarStop(val name: String, val address: String?, val number: Int)

data class CarRoute(val index: Int, val distanceM: Double, val durationS: Long, val via: String?)

data class CarTrip(
    val phase: String,
    val available: Boolean,
    val imperial: Boolean,
    val routing: Boolean,
    val error: String?,
    val destinationName: String?,
    val destinationAddress: String?,
    val destinationLat: Double?,
    val destinationLon: Double?,
    val routes: List<CarRoute>,
    val routeIndex: Int,
    val routeId: String?,
    val voiceOn: Boolean,
    val arrived: Boolean,
    val rerouting: Boolean,
    val lat: Double?,
    val lon: Double?,
    val heading: Double?,
    val step: CarStep?,
    val then: CarStep?,
    val currentRoad: String?,
    val remainingM: Double?,
    val remainingS: Long?,
    val etaMs: Long?,
    val overlay: CarOverlaySwitches = CarOverlaySwitches.DEFAULT,
    val climb: CarClimb? = null,
    val overview: CarOverview? = null,
    val palette: CarOverlayColors? = null,
    val stops: List<CarStop> = emptyList(),
) {
    val guiding: Boolean get() = phase == "guiding"
    val previewing: Boolean get() = phase == "previewing"

    /**
     * This trip with guidance over, as the phone pushes it once its own guidance has ended (lib/car/car_trip.dart): back to
     * browsing with no routes, step, estimate, climb or overview. The car side uses it to say so at once, before the phone has
     * answered ([CarLink.stopGuidance]).
     */
    fun ended(): CarTrip = copy(
        phase = "browsing", routing = false, error = null, routes = emptyList(), routeIndex = 0, routeId = null, arrived = false,
        rerouting = false, step = null, then = null, currentRoad = null, remainingM = null, remainingS = null, etaMs = null,
        climb = null, overview = null, stops = emptyList(),
    )

    companion object {
        val EMPTY = CarTrip(
            phase = "browsing", available = false, imperial = false, routing = false, error = null, destinationName = null,
            destinationAddress = null, destinationLat = null, destinationLon = null, routes = emptyList(), routeIndex = 0,
            routeId = null, voiceOn = true, arrived = false, rerouting = false, lat = null, lon = null, heading = null, step = null,
            then = null, currentRoad = null, remainingM = null, remainingS = null, etaMs = null,
        )

        fun from(m: Map<String, Any?>): CarTrip {
            val dest = m["destination"].asMap()
            val pos = m["position"].asMap()
            return CarTrip(
                phase = m["phase"] as? String ?: "browsing",
                available = m["available"] == true,
                imperial = m["units"] == "imperial",
                routing = m["routing"] == true,
                error = m["error"] as? String,
                destinationName = dest?.get("name") as? String,
                destinationAddress = (dest?.get("address") as? String)?.takeIf { it.isNotBlank() },
                destinationLat = dest?.get("lat").asDouble(),
                destinationLon = dest?.get("lon").asDouble(),
                routes = (m["routes"] as? List<*>).orEmpty().mapNotNull { r ->
                    val x = r.asMap() ?: return@mapNotNull null
                    CarRoute(
                        index = (x["index"] as? Number)?.toInt() ?: 0,
                        distanceM = x["distanceM"].asDouble() ?: 0.0,
                        durationS = (x["durationS"] as? Number)?.toLong() ?: 0L,
                        via = x["via"] as? String,
                    )
                },
                routeIndex = (m["routeIndex"] as? Number)?.toInt() ?: 0,
                routeId = m["routeId"] as? String,
                voiceOn = m["voiceOn"] != false,
                arrived = m["arrived"] == true,
                rerouting = m["rerouting"] == true,
                lat = pos?.get("lat").asDouble(),
                lon = pos?.get("lon").asDouble(),
                heading = pos?.get("heading").asDouble(),
                step = step(m["step"]),
                then = step(m["then"]),
                currentRoad = m["currentRoad"] as? String,
                remainingM = m["remainingM"].asDouble(),
                remainingS = (m["remainingS"] as? Number)?.toLong(),
                etaMs = (m["etaMs"] as? Number)?.toLong(),
                overlay = CarOverlaySwitches.from(m["overlay"]),
                climb = CarClimb.from(m["climb"]),
                overview = CarOverview.from(m["overview"]),
                palette = CarOverlayColors.from(m["palette"]),
                stops = (m["stops"] as? List<*>).orEmpty().mapIndexedNotNull { i, s ->
                    val x = s.asMap() ?: return@mapIndexedNotNull null
                    CarStop(
                        name = x["name"] as? String ?: return@mapIndexedNotNull null,
                        address = (x["address"] as? String)?.takeIf { it.isNotBlank() },
                        number = (x["number"] as? Number)?.toInt() ?: (i + 1),
                    )
                },
            )
        }

        private fun step(v: Any?): CarStep? {
            val s = v.asMap() ?: return null
            return CarStep(
                turn = s["turn"] as? String ?: "straight",
                type = s["type"] as? String ?: "",
                cue = s["cue"] as? String ?: "",
                road = (s["road"] as? String)?.takeIf { it.isNotBlank() },
                distanceM = s["distanceM"].asDouble() ?: 0.0,
            )
        }
    }
}

/** A place the car can go to, as Dart lists them (saved places, search results). */
data class CarPlace(val id: String, val name: String, val address: String?, val lat: Double, val lon: Double, val distanceM: Double?) {
    companion object {
        fun from(v: Any?): CarPlace? {
            val m = v.asMap() ?: return null
            val id = m["id"] as? String ?: return null
            return CarPlace(
                id = id,
                name = m["name"] as? String ?: "",
                address = (m["address"] as? String)?.takeIf { it.isNotBlank() },
                lat = m["lat"].asDouble() ?: return null,
                lon = m["lon"].asDouble() ?: return null,
                distanceM = m["distanceM"].asDouble(),
            )
        }

        fun list(v: Any?): List<CarPlace> = (v as? List<*>).orEmpty().mapNotNull { from(it) }
    }
}

@Suppress("UNCHECKED_CAST")
internal fun Any?.asMap(): Map<String, Any?>? = this as? Map<String, Any?>

internal fun Any?.asDouble(): Double? = (this as? Number)?.toDouble()
