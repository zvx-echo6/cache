package com.happylittlellc.cache.car

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The car side of the `co.cache/car` channel (lib/car/car_bridge.dart is the other side).
 *
 * Dart pushes the trip (`trip`), the route line (`route`), that the map style changed (`styleChanged`), short notices (`notice`)
 * and spoken prompts (`prompt`, `promptStop`). The car asks Dart for places, directions, start and stop, through [call].
 * Main thread only, as the Car App Library and Flutter channels both are.
 */
object CarLink {
    interface Listener {
        fun onTrip(trip: CarTrip) {}
        fun onRoute(geojson: String, bounds: DoubleArray?) {}
        fun onStyleChanged() {}
        fun onNotice(text: String) {}
        fun onDartReady() {}
    }

    private var channel: MethodChannel? = null
    private val listeners = LinkedHashSet<Listener>()
    private val main = Handler(Looper.getMainLooper())

    /** Dart said hello: its handler is set and calls to it are answered. */
    var dartReady = false
        private set

    /** A car session is attached. */
    var carConnected = false
        private set

    var trip: CarTrip = CarTrip.EMPTY
        private set
    var routeGeoJson: String? = null
        private set
    var routeBounds: DoubleArray? = null
        private set

    /** Plays the prompts' audio focus; set by the car session. */
    var audio: CarAudio? = null

    fun attach(engine: FlutterEngine) {
        channel?.setMethodCallHandler(null)
        dartReady = false
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "co.cache/car").also {
            it.setMethodCallHandler { call, result -> handle(call, result) }
        }
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        dartReady = false
    }

    fun addListener(l: Listener) {
        listeners.add(l)
    }

    fun removeListener(l: Listener) {
        listeners.remove(l)
    }

    fun setCarConnected(on: Boolean) {
        carConnected = on
        if (!on) {
            trip = CarTrip.EMPTY
            routeGeoJson = null
            routeBounds = null
        }
        if (dartReady) channel?.invokeMethod("connected", mapOf("on" to on))
    }

    /** For the tests: answers in place of Dart (a car session with no Flutter engine). */
    internal var dartForTests: ((method: String, args: Any?, done: (Any?) -> Unit) -> Unit)? = null

    /** Asks Dart; [done] gets the answer, or null when Dart is not there yet or failed. */
    fun call(method: String, args: Any? = null, done: (Any?) -> Unit = {}) {
        dartForTests?.let { fake ->
            main.post { fake(method, args, done) }
            return
        }
        val ch = channel
        if (ch == null || !dartReady) {
            main.post { done(null) }
            return
        }
        ch.invokeMethod(method, args, object : MethodChannel.Result {
            override fun success(result: Any?) = done(result)
            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) = done(null)
            override fun notImplemented() = done(null)
        })
    }

    /** Tells each listener; one that fails is logged and the others still hear (the reply to Dart is already sent). */
    private inline fun each(f: (Listener) -> Unit) {
        for (l in listeners.toList()) {
            try {
                f(l)
            } catch (e: Exception) {
                android.util.Log.w("CacheCar", "car listener failed", e)
            }
        }
    }

    /** For the tests: what Dart would push. */
    internal fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hello" -> {
                dartReady = true
                result.success(mapOf("connected" to carConnected))
                each { it.onDartReady() }
            }
            "trip" -> {
                @Suppress("UNCHECKED_CAST")
                val t = CarTrip.from(call.arguments as? Map<String, Any?> ?: emptyMap())
                trip = t
                result.success(null)
                each { it.onTrip(t) }
            }
            "route" -> {
                val geo = call.argument<String>("geojson") ?: EMPTY_GEOJSON
                val b = (call.argument<List<Number>>("bounds"))?.map { it.toDouble() }?.toDoubleArray()
                routeGeoJson = geo
                routeBounds = b
                result.success(null)
                each { it.onRoute(geo, b) }
            }
            "styleChanged" -> {
                result.success(null)
                each { it.onStyleChanged() }
            }
            "notice" -> {
                result.success(null)
                val text = call.argument<String>("text") ?: ""
                if (text.isNotBlank()) each { it.onNotice(text) }
            }
            "prompt" -> {
                audio?.prompt(call.argument<String>("text") ?: "")
                result.success(null)
            }
            "promptStop" -> {
                audio?.release()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** For the tests. */
    internal fun reset() {
        listeners.clear()
        trip = CarTrip.EMPTY
        routeGeoJson = null
        routeBounds = null
        carConnected = false
        dartReady = false
        channel = null
        audio = null
        dartForTests = null
    }

    const val EMPTY_GEOJSON = "{\"type\":\"FeatureCollection\",\"features\":[]}"
}
