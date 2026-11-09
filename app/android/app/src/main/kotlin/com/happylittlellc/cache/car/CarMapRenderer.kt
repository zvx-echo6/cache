package com.happylittlellc.cache.car

import android.app.Presentation
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.ViewGroup
import androidx.car.app.CarContext
import androidx.car.app.SurfaceCallback
import androidx.car.app.SurfaceContainer
import androidx.car.app.model.Action
import androidx.car.app.model.ActionStrip
import androidx.car.app.navigation.model.MapController
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.geometry.LatLngBounds
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapLibreMapOptions
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.Style
import org.maplibre.android.style.expressions.Expression
import org.maplibre.android.style.layers.CircleLayer
import org.maplibre.android.style.layers.LineLayer
import org.maplibre.android.style.layers.Property
import org.maplibre.android.style.layers.PropertyFactory
import org.maplibre.android.style.sources.GeoJsonSource
import kotlin.math.ln
import kotlin.math.max

/**
 * Draws Cache's map on the car's screen.
 *
 * The host gives a Surface ([SurfaceCallback.onSurfaceAvailable]). MapLibre Native Android (the same build the phone's
 * maplibre_gl plugin ships, 13.5.0) has no public call to render into a Surface it did not make: its renderers are tied to its
 * own SurfaceView or TextureView. So the surface becomes a VirtualDisplay, and a Presentation on that display holds an ordinary
 * MapLibre MapView, as Google's car documentation shows for drawing Views to the car surface. This MapView is the car's own: the
 * phone's Flutter map is not touched or moved, and both read the same offline tiles from the core's tile server on 127.0.0.1
 * with the same style, which Dart builds (the light or dark map palette, as the car asks).
 *
 * Only map content is drawn on the surface (quality rule NF-2): the base map, the route, the destination and the position.
 * The turn, distances and arrival time are the templates'.
 */
class CarMapRenderer(private val carContext: CarContext) : SurfaceCallback, CarLink.Listener {
    private val main = Handler(Looper.getMainLooper())
    private var display: VirtualDisplay? = null
    private var presentation: Presentation? = null
    private var mapView: MapView? = null
    private var map: MapLibreMap? = null
    private var style: Style? = null
    private var styleAttempt = 0
    private var colors: Map<String, String> = DEFAULT_COLORS
    private var dark = carContext.isDarkMode
    private var stable: Rect? = null
    private var visible: Rect? = null
    private var width = 0
    private var height = 0
    private var lastCameraPhase: String? = null

    /** The camera keeps the position in view (the Recenter button turns it back on after panning). */
    var following = true
        private set

    /** The host's pan mode (rotary and touchpad controllers move the map while it is on). */
    var panMode = false

    /** Called when [following] changes, so the screens can show or hide Recenter. */
    var onFollowingChanged: (() -> Unit)? = null

    init {
        CarLink.addListener(this)
    }

    // ---- the surface -------------------------------------------------------------------------------------------

    override fun onSurfaceAvailable(surfaceContainer: SurfaceContainer) {
        val surface = surfaceContainer.surface ?: return
        releaseMap()
        width = surfaceContainer.width
        height = surfaceContainer.height
        try {
            MapLibre.getInstance(carContext.applicationContext)
            // The tiles come from the app's own server on 127.0.0.1: never let MapLibre think it is offline (as the phone's map).
            MapLibre.setConnected(true)
            val dm = carContext.getSystemService(DisplayManager::class.java)
            val vd = dm.createVirtualDisplay("CacheCarMap", width, height, surfaceContainer.dpi, surface, 0)
            display = vd
            val p = Presentation(carContext, vd.display)
            val options = MapLibreMapOptions.createFromAttributes(p.context)
                .compassEnabled(false)
                .logoEnabled(false)
                .attributionEnabled(false)
                .textureMode(false)
            val mv = MapView(p.context, options)
            mv.layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            p.setContentView(mv)
            mv.onCreate(null)
            mv.onStart()
            mv.onResume()
            p.show()
            presentation = p
            mapView = mv
            mv.getMapAsync { m -> onMap(m) }
        } catch (e: Exception) {
            Log.w(TAG, "car map could not start", e)
        }
    }

    override fun onSurfaceDestroyed(surfaceContainer: SurfaceContainer) {
        releaseMap()
    }

    override fun onVisibleAreaChanged(visibleArea: Rect) {
        visible = Rect(visibleArea)
        follow(force = true)
    }

    override fun onStableAreaChanged(stableArea: Rect) {
        stable = Rect(stableArea)
        follow(force = true)
    }

    // ---- the map's gestures and buttons (pan mode, quality item: users can move the map) ------------------------------------

    override fun onScroll(distanceX: Float, distanceY: Float) {
        val m = map ?: return
        setFollowing(false)
        m.scrollBy(-distanceX, -distanceY, 0)
    }

    override fun onFling(velocityX: Float, velocityY: Float) {
        val m = map ?: return
        setFollowing(false)
        m.scrollBy(velocityX * 0.15f, velocityY * 0.15f, 300)
    }

    override fun onScale(focusX: Float, focusY: Float, scaleFactor: Float) {
        val m = map ?: return
        if (scaleFactor <= 0f) return
        val by = ln(scaleFactor.toDouble()) / ln(2.0)
        if (focusX < 0 || focusY < 0) {
            m.moveCamera(CameraUpdateFactory.zoomBy(by))
        } else {
            setFollowing(false)
            m.moveCamera(CameraUpdateFactory.zoomBy(by, android.graphics.Point(focusX.toInt(), focusY.toInt())))
        }
    }

    fun zoomIn() {
        map?.moveCamera(CameraUpdateFactory.zoomIn())
    }

    fun zoomOut() {
        map?.moveCamera(CameraUpdateFactory.zoomOut())
    }

    fun recenter() {
        setFollowing(true)
        lastCameraPhase = null
        follow(force = true)
    }

    private fun setFollowing(on: Boolean) {
        if (following == on) return
        following = on
        onFollowingChanged?.invoke()
    }

    /** The map buttons: Pan (needed for the gestures above), zoom in and out, and Recenter after the map was moved. */
    fun mapActionStrip(): ActionStrip {
        val b = ActionStrip.Builder().addAction(Action.PAN)
        if (!following) b.addAction(Action.Builder().setIcon(CarIcons.recenter).setOnClickListener { recenter() }.build())
        b.addAction(Action.Builder().setIcon(CarIcons.zoomIn).setOnClickListener { zoomIn() }.build())
        b.addAction(Action.Builder().setIcon(CarIcons.zoomOut).setOnClickListener { zoomOut() }.build())
        return b.build()
    }

    fun mapController(): MapController =
        MapController.Builder().setMapActionStrip(mapActionStrip()).setPanModeListener { on -> panMode = on }.build()

    // ---- light and dark (quality rule MR-1) -------------------------------------------------------------------------

    fun setDark(on: Boolean) {
        if (on == dark) return
        dark = on
        loadStyle()
    }

    // ---- style and overlays ----------------------------------------------------------------------------------------

    private fun onMap(m: MapLibreMap) {
        map = m
        m.uiSettings.setAllGesturesEnabled(false)
        m.uiSettings.isLogoEnabled = false
        m.uiSettings.isAttributionEnabled = false
        m.uiSettings.isCompassEnabled = false
        m.setMinZoomPreference(2.0)
        m.setMaxZoomPreference(19.0)
        val t = CarLink.trip
        val lat = t.lat ?: t.destinationLat
        val lon = t.lon ?: t.destinationLon
        if (lat != null && lon != null) {
            m.moveCamera(CameraUpdateFactory.newCameraPosition(CameraPosition.Builder().target(LatLng(lat, lon)).zoom(14.0).build()))
        } else {
            m.moveCamera(CameraUpdateFactory.newCameraPosition(CameraPosition.Builder().target(LatLng(39.5, -98.35)).zoom(3.0).build()))
        }
        styleAttempt = 0
        loadStyle()
    }

    private fun loadStyle() {
        if (map == null) return
        val attempt = ++styleAttempt
        CarLink.call("style", mapOf("dark" to dark)) { r ->
            val m = map ?: return@call
            if (attempt != styleAttempt) return@call
            val res = r.asMap()
            val json = res?.get("style") as? String
            if (json == null) {
                // Dart or the layer engine is still starting: ask again shortly.
                main.postDelayed({ if (attempt == styleAttempt) loadStyle() }, 1500)
                return@call
            }
            @Suppress("UNCHECKED_CAST")
            colors = DEFAULT_COLORS + ((res["colors"] as? Map<String, String>) ?: emptyMap())
            style = null
            m.setStyle(Style.Builder().fromJson(json)) { st ->
                if (attempt != styleAttempt) return@setStyle
                style = st
                addOverlays(st)
                applyRoute(CarLink.routeGeoJson ?: CarLink.EMPTY_GEOJSON)
                applyTrip(CarLink.trip)
                lastCameraPhase = null
                follow(force = true)
            }
        }
    }

    private fun addOverlays(st: Style) {
        st.addSource(GeoJsonSource(SRC_ROUTE, CarLink.EMPTY_GEOJSON))
        st.addSource(GeoJsonSource(SRC_DEST, CarLink.EMPTY_GEOJSON))
        st.addSource(GeoJsonSource(SRC_POS, CarLink.EMPTY_GEOJSON))
        val isAlt = Expression.eq(Expression.get("alt"), Expression.literal(true))
        val isMain = Expression.eq(Expression.get("alt"), Expression.literal(false))
        val isRoad = Expression.eq(Expression.get("kind"), Expression.literal("road"))
        st.addLayer(
            LineLayer("car-route-alt", SRC_ROUTE).withFilter(isAlt).withProperties(
                PropertyFactory.lineColor(colors.getValue("routeAlternate")), PropertyFactory.lineWidth(6f),
                PropertyFactory.lineCap(Property.LINE_CAP_ROUND), PropertyFactory.lineJoin(Property.LINE_JOIN_ROUND),
            ),
        )
        st.addLayer(
            LineLayer("car-route-casing", SRC_ROUTE).withFilter(isMain).withProperties(
                PropertyFactory.lineColor(colors.getValue("routeCasing")), PropertyFactory.lineWidth(12f),
                PropertyFactory.lineCap(Property.LINE_CAP_ROUND), PropertyFactory.lineJoin(Property.LINE_JOIN_ROUND),
            ),
        )
        st.addLayer(
            LineLayer("car-route", SRC_ROUTE).withFilter(Expression.all(isMain, isRoad)).withProperties(
                PropertyFactory.lineColor(colors.getValue("route")), PropertyFactory.lineWidth(8f),
                PropertyFactory.lineCap(Property.LINE_CAP_ROUND), PropertyFactory.lineJoin(Property.LINE_JOIN_ROUND),
            ),
        )
        st.addLayer(
            LineLayer("car-route-offroad", SRC_ROUTE).withFilter(Expression.all(isMain, Expression.not(isRoad))).withProperties(
                PropertyFactory.lineColor(colors.getValue("routeOffroad")), PropertyFactory.lineWidth(8f),
                PropertyFactory.lineDasharray(arrayOf(1.2f, 0.8f)),
            ),
        )
        st.addLayer(
            CircleLayer("car-dest", SRC_DEST).withProperties(
                PropertyFactory.circleColor(colors.getValue("pin")), PropertyFactory.circleRadius(9f),
                PropertyFactory.circleStrokeColor("#ffffff"), PropertyFactory.circleStrokeWidth(3f),
            ),
        )
        st.addLayer(
            CircleLayer("car-pos", SRC_POS).withProperties(
                PropertyFactory.circleColor(colors.getValue("position")), PropertyFactory.circleRadius(10f),
                PropertyFactory.circleStrokeColor(colors.getValue("positionRing")), PropertyFactory.circleStrokeWidth(4f),
            ),
        )
    }

    override fun onTrip(trip: CarTrip) {
        applyTrip(trip)
        follow(force = trip.phase != lastCameraPhase)
    }

    override fun onRoute(geojson: String, bounds: DoubleArray?) {
        applyRoute(geojson)
        lastCameraPhase = null
        follow(force = true)
    }

    override fun onStyleChanged() {
        main.removeCallbacks(reload)
        main.postDelayed(reload, 400)
    }

    private val reload = Runnable { loadStyle() }

    private fun applyRoute(geojson: String) {
        style?.getSourceAs<GeoJsonSource>(SRC_ROUTE)?.setGeoJson(geojson)
    }

    private fun applyTrip(t: CarTrip) {
        val st = style ?: return
        st.getSourceAs<GeoJsonSource>(SRC_POS)?.setGeoJson(point(t.lat, t.lon))
        val showDest = t.phase != "browsing"
        st.getSourceAs<GeoJsonSource>(SRC_DEST)?.setGeoJson(if (showDest) point(t.destinationLat, t.destinationLon) else CarLink.EMPTY_GEOJSON)
    }

    /** The camera for the phase: the whole route while choosing one, close behind the position and turned to the heading while
     * guiding, the position while looking at the map. Nothing moves while the driver has panned away. */
    private fun follow(force: Boolean) {
        val m = map ?: return
        if (!following) return
        val t = CarLink.trip
        val area = stable ?: visible ?: Rect(0, 0, width, height)
        val pad = doubleArrayOf(area.left.toDouble(), area.top.toDouble(), max(0, width - area.right).toDouble(), max(0, height - area.bottom).toDouble())
        val phase = t.phase
        if (phase == "previewing") {
            val b = CarLink.routeBounds
            if (!force && lastCameraPhase == phase) return
            lastCameraPhase = phase
            if (b != null && b.size == 4) {
                // The route's bounds as Dart sends them (MapRoute.bounds): south, west, north, east.
                val bounds = LatLngBounds.Builder().include(LatLng(b[0], b[1])).include(LatLng(b[2], b[3])).build()
                m.moveCamera(CameraUpdateFactory.newLatLngBounds(bounds, pad[0].toInt() + 40, pad[1].toInt() + 40, pad[2].toInt() + 40, pad[3].toInt() + 40))
            } else if (t.destinationLat != null && t.destinationLon != null) {
                m.moveCamera(CameraUpdateFactory.newCameraPosition(CameraPosition.Builder().target(LatLng(t.destinationLat, t.destinationLon)).zoom(13.0).build()))
            }
            return
        }
        val lat = t.lat ?: return
        val lon = t.lon ?: return
        lastCameraPhase = phase
        val guiding = phase == "guiding"
        // While guiding the position sits low in the visible area, so more of the road ahead shows.
        val extraTop = if (guiding) (area.height() * 0.35).toDouble() else 0.0
        val cam = CameraPosition.Builder()
            .target(LatLng(lat, lon))
            .zoom(if (guiding) 16.0 else (m.cameraPosition.zoom.takeIf { !force } ?: 14.0))
            .bearing(if (guiding) (t.heading ?: m.cameraPosition.bearing) else 0.0)
            .tilt(if (guiding) 45.0 else 0.0)
            .padding(pad[0], pad[1] + extraTop, pad[2], pad[3])
            .build()
        m.easeCamera(CameraUpdateFactory.newCameraPosition(cam), if (force) 1 else 900)
    }

    private fun point(lat: Double?, lon: Double?): String =
        if (lat == null || lon == null) CarLink.EMPTY_GEOJSON
        else "{\"type\":\"FeatureCollection\",\"features\":[{\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[$lon,$lat]},\"properties\":{}}]}"

    private fun releaseMap() {
        styleAttempt++
        main.removeCallbacks(reload)
        style = null
        map = null
        mapView?.let {
            try {
                it.onPause()
                it.onStop()
                it.onDestroy()
            } catch (e: Exception) {
                Log.w(TAG, "car map release", e)
            }
        }
        mapView = null
        presentation?.dismiss()
        presentation = null
        display?.release()
        display = null
    }

    /** The car session ended. */
    fun release() {
        CarLink.removeListener(this)
        releaseMap()
    }

    companion object {
        private const val TAG = "CacheCarMap"
        private const val SRC_ROUTE = "car-route-src"
        private const val SRC_DEST = "car-dest-src"
        private const val SRC_POS = "car-pos-src"
        private val DEFAULT_COLORS = mapOf(
            "route" to "#2f7df6", "routeCasing" to "#0b3a8a", "routeOffroad" to "#d9822b", "routeAlternate" to "#8aa4c8",
            "position" to "#2f7df6", "positionRing" to "#ffffff", "pin" to "#d93a3a",
        )
    }
}
