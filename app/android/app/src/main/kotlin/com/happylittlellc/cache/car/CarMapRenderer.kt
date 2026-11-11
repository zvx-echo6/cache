package com.happylittlellc.cache.car

import android.animation.ValueAnimator
import android.app.Presentation
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.ViewGroup
import android.view.animation.LinearInterpolator
import android.widget.FrameLayout
import android.graphics.Bitmap
import android.graphics.Color
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
import org.maplibre.android.style.layers.SymbolLayer
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.geojson.Point
import kotlin.math.abs
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
 * Quality rule NF-2 says only map content is drawn on the surface: the base map, the route, the destination and the position,
 * with the turn, distances and arrival time left to the templates. Two things here are deliberately drawn on the surface anyway:
 * the climb-ahead card (bottom left) and the route mini map (bottom right), plus a grade badge at the steepest point and the
 * driven part of the route in faded grey on the map. This is in tension with NF-2. The owner chose to try it in review. Both
 * pieces are on by default, and the defaults are single constants in lib/car/car_overlay.dart (kCarClimbAheadDefault,
 * kCarRouteMiniMapDefault), so flipping them is a one-line change.
 *
 * How the pieces are composited: the Presentation holds a FrameLayout with the MapView and, above it, a [CarOverlayView], an
 * ordinary View whose onDraw calls [CarOverlayPainter] (pure Canvas drawing). That is the cleanest fit for the VirtualDisplay
 * set-up: the whole Presentation is already what the host shows, so one more View in it needs no second surface, no second
 * renderer and no MapLibre change, and it sits exactly over the map in the same pixels. The pieces are static: the View repaints
 * only in steps (at most once every few seconds) and nothing is animated or touchable. The grade badge and the driven path are
 * MapLibre layers (they are part of the map, so they follow the camera).
 *
 * The vehicle is an arrow (CarOverlayPainter.arrowBitmap, a symbol layer above the route and the badge) turned to the heading,
 * with its turn tied to the map, so it points the right way whether the map is turned to the heading or north is up. While no
 * heading was ever known it is the plain dot instead.
 *
 * The vehicle is the one thing on the map that is animated. Positions come about once a second; between one and the next the
 * marker and the camera glide together at a steady rate (one ValueAnimator drives both: see moveMarker and onGlideFrame), and
 * where a glide would show movement that did not happen the marker jumps (CarMarkerMotion.snaps). The animator runs only
 * between two different positions: a parked car draws nothing.
 *
 * Threads: everything here runs on the main thread, which is the thread MapLibre must be called on. The host's surface
 * callbacks, the phone's pushes (CarLink) and the screens' buttons all arrive there, and the animator is started there, so the
 * frames it gives are on the main thread too.
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
    private var overlayView: CarOverlayView? = null

    /** The route overview screen is up: the camera shows the whole route instead of following the position. */
    private var overview = false
    private var routeCoords: List<DoubleArray> = emptyList()
    private var badgeKey: String? = null
    private var routeColorKey: String? = null

    /** The map's pixels per density-independent pixel (the car surface's, which the map's own View has too). */
    private var density = 1f

    /** The vehicle's two markers (the arrow, and the dot for when no heading is known), kept so that showing a heading does
     * not look them up in the style each time. Both belong to the present style and go with it. */
    private var arrowLayer: SymbolLayer? = null
    private var dotLayer: CircleLayer? = null

    /** Which of the two is showing (null: neither yet), and the turn the arrow was last given. */
    private var arrowShown: Boolean? = null
    private var shownRotation = Float.NaN

    /** The last heading the phone gave: the arrow keeps it while a position comes without one. */
    private var lastHeading: Double? = null

    /** The position's source in the present style, kept so that a frame does not look it up. */
    private var posSource: GeoJsonSource? = null

    // The vehicle's marker. Plain numbers (a heading that is not known is NaN) so that a frame makes no objects for them.

    /** A position was drawn; drawnLat, drawnLon and drawnHeading are where the marker is on the map right now. */
    private var hasMarker = false
    private var drawnLat = 0.0
    private var drawnLon = 0.0
    private var drawnHeading = Double.NaN

    /** The glide in hand: from where the marker was when the newest position came, to that position. */
    private var fromLat = 0.0
    private var fromLon = 0.0
    private var fromHeading = Double.NaN
    private var toLat = 0.0
    private var toLon = 0.0
    private var toHeading = Double.NaN

    /** When the newest position came (SystemClock.elapsedRealtime), and the trip's phase it came in. */
    private var lastFixAt = 0L
    private var markerPhase: String? = null

    /** The one animator, made when first needed and used again for every glide. */
    private var glide: ValueAnimator? = null

    /** A frame of the glide: the marker, and with it the camera, at the animator's share of the way. Linear, so the share is
     * the share of the time. Nothing is sent to the map when the frame is where the marker already is. */
    private val onGlideFrame = ValueAnimator.AnimatorUpdateListener { a ->
        val f = a.animatedFraction.toDouble()
        val lat = CarMarkerMotion.lerp(fromLat, toLat, f)
        val lon = CarMarkerMotion.lerp(fromLon, toLon, f)
        val heading = when {
            toHeading.isNaN() -> Double.NaN
            fromHeading.isNaN() -> toHeading
            else -> CarMarkerMotion.lerpHeading(fromHeading, toHeading, f)
        }
        if (lat != drawnLat || lon != drawnLon || !sameHeading(heading, drawnHeading)) {
            drawMarker(lat, lon, heading)
            glideCamera()
        }
    }

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
        density = surfaceContainer.dpi / 160f
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
            val frame = FrameLayout(p.context)
            frame.layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            frame.addView(mv, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
            val ov = CarOverlayView(p.context, surfaceContainer.dpi / 160f)
            ov.setSurfaceSize(width, height)
            ov.setAreas(visible, stable)
            ov.setOverview(overview)
            ov.setTrip(CarLink.trip, dark, now = true)
            frame.addView(ov, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
            overlayView = ov
            p.setContentView(frame)
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
        overlayView?.setAreas(visible, stable)
        follow(force = true)
    }

    override fun onStableAreaChanged(stableArea: Rect) {
        stable = Rect(stableArea)
        overlayView?.setAreas(visible, stable)
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

    /** The whole route in view (the route overview screen), and back to following the position when it goes. */
    fun setOverview(on: Boolean) {
        if (overview == on) return
        overview = on
        // The climb card and the mini map are not drawn over the overview (CarOverlayPainter.draw).
        overlayView?.setOverview(on)
        following = true
        lastCameraPhase = null
        onFollowingChanged?.invoke()
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
        overlayView?.setTrip(CarLink.trip, dark, now = true)
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
            dropStyle()
            m.setStyle(Style.Builder().fromJson(json)) { st ->
                if (attempt != styleAttempt) return@setStyle
                style = st
                addOverlays(st)
                applyRoute(CarLink.routeGeoJson ?: CarLink.EMPTY_GEOJSON)
                applyTrip(CarLink.trip)
                // The new style's position source is empty: the marker is drawn into it at once.
                moveMarker(CarLink.trip, force = true)
                lastCameraPhase = null
                follow(force = true)
            }
        }
    }

    private fun addOverlays(st: Style) {
        st.addSource(GeoJsonSource(SRC_ROUTE, CarLink.EMPTY_GEOJSON))
        st.addSource(GeoJsonSource(SRC_DEST, CarLink.EMPTY_GEOJSON))
        st.addSource(GeoJsonSource(SRC_POS, CarLink.EMPTY_GEOJSON))
        st.addSource(GeoJsonSource(SRC_DRIVEN, CarLink.EMPTY_GEOJSON))
        st.addSource(GeoJsonSource(SRC_BADGE, CarLink.EMPTY_GEOJSON))
        badgeKey = null
        routeColorKey = null
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
        // The part already driven, faded grey, over the route line (the grey comes from the theme tokens, Dart's palette block).
        st.addLayer(
            LineLayer("car-route-driven", SRC_DRIVEN).withProperties(
                PropertyFactory.lineColor(overlayColors()?.routeDriven?.let { hex(it) } ?: "#4a5866"), PropertyFactory.lineWidth(8f),
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
            SymbolLayer("car-grade-badge", SRC_BADGE).withProperties(
                PropertyFactory.iconImage(BADGE_IMAGE), PropertyFactory.iconAllowOverlap(true), PropertyFactory.iconIgnorePlacement(true),
            ),
        )
        // The vehicle, above everything else on the map: the dot while no heading is known, otherwise the arrow. Both start
        // hidden; showHeading shows the one that applies. The arrow's picture is made here, so each style (each theme, day
        // and night) has it in its own colors.
        val dot = CircleLayer("car-pos-dot", SRC_POS).withProperties(
            PropertyFactory.circleColor(colors.getValue("position")), PropertyFactory.circleRadius(CarOverlayPainter.POS_RADIUS),
            PropertyFactory.circleStrokeColor(colors.getValue("positionRing")), PropertyFactory.circleStrokeWidth(CarOverlayPainter.POS_RING),
            PropertyFactory.visibility(Property.NONE),
        )
        st.addLayer(dot)
        st.addImage(ARROW_IMAGE, CarOverlayPainter.arrowBitmap(colorOf("position"), colorOf("positionRing"), density))
        // Turned with the map (so the heading is a compass heading whatever way the map is turned), but upright on the screen
        // when the map is tilted, as the dot was: its size on the screen does not change with the tilt.
        val arrow = SymbolLayer("car-pos", SRC_POS).withProperties(
            PropertyFactory.iconImage(ARROW_IMAGE), PropertyFactory.iconAllowOverlap(true), PropertyFactory.iconIgnorePlacement(true),
            PropertyFactory.iconRotationAlignment(Property.ICON_ROTATION_ALIGNMENT_MAP),
            PropertyFactory.iconPitchAlignment(Property.ICON_PITCH_ALIGNMENT_VIEWPORT),
            PropertyFactory.iconRotate(0f), PropertyFactory.visibility(Property.NONE),
        )
        st.addLayer(arrow)
        posSource = st.getSourceAs<GeoJsonSource>(SRC_POS)
        dotLayer = dot
        arrowLayer = arrow
        arrowShown = null
        shownRotation = Float.NaN
    }

    /** One of the style's colors as a number (they come as "#rrggbb"); the default when it does not read as a color. */
    private fun colorOf(key: String): Int = try {
        Color.parseColor(colors.getValue(key))
    } catch (e: IllegalArgumentException) {
        Color.parseColor(DEFAULT_COLORS.getValue(key))
    }

    /** The marker for [heading] (degrees from north; NaN when none is known): the arrow turned to it, or the dot with none.
     * Only what changed is sent to the map; the arrow is turned again once the heading is [ROTATE_STEP] away from its turn. */
    private fun showHeading(heading: Double) {
        val arrow = !heading.isNaN()
        if (arrowShown != arrow) {
            arrowShown = arrow
            arrowLayer?.setProperties(PropertyFactory.visibility(if (arrow) Property.VISIBLE else Property.NONE))
            dotLayer?.setProperties(PropertyFactory.visibility(if (arrow) Property.NONE else Property.VISIBLE))
        }
        if (!arrow) return
        val r = heading.toFloat()
        if (shownRotation.isNaN() || abs(r - shownRotation) >= ROTATE_STEP) {
            shownRotation = r
            arrowLayer?.setProperties(PropertyFactory.iconRotate(r))
        }
    }

    /** The present style is going (a new one is loading, or the map is released): nothing of it is used again. */
    private fun dropStyle() {
        style = null
        posSource = null
        arrowLayer = null
        dotLayer = null
    }

    override fun onTrip(trip: CarTrip) {
        overlayView?.setTrip(trip, dark, now = false)
        applyTrip(trip)
        val force = (if (overview) "overview" else trip.phase) != lastCameraPhase
        // While the driver has panned away the camera does not move, so its phase is not kept up: that must not make the
        // marker jump each second.
        val snapped = moveMarker(trip, force = force && following)
        follow(force, snapped)
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
        routeCoords = CarOverlayGeo.mainRoute(geojson)
        applyDriven(CarLink.trip)
    }

    private fun overlayColors(t: CarTrip = CarLink.trip): CarOverlayColors? = t.palette?.forMode(dark)

    private fun hex(c: Int): String = String.format("#%06x", c and 0xFFFFFF)

    /** The driven part of the route (faded grey) and the grade badge at the steepest point; both follow the trip's figures. */
    private fun applyDriven(t: CarTrip) {
        val st = style ?: return
        val ov = t.overview
        val driven = if (t.guiding && ov != null) CarOverlayGeo.drivenGeoJson(routeCoords, ov.drivenFraction) else CarLink.EMPTY_GEOJSON
        st.getSourceAs<GeoJsonSource>(SRC_DRIVEN)?.setGeoJson(driven)
        val pal = overlayColors(t)
        if (pal != null) {
            val key = "${pal.theme}|${dark}"
            if (key != routeColorKey) {
                routeColorKey = key
                st.getLayer("car-route")?.setProperties(PropertyFactory.lineColor(hex(pal.route)))
                st.getLayer("car-route-driven")?.setProperties(PropertyFactory.lineColor(hex(pal.routeDriven)))
            }
        }
        // The badge shows with the climb switch, at the steepest point ahead.
        val g = ov?.steepGradePct
        val showBadge = t.guiding && t.overlay.climb && pal != null && g != null && ov.steepLat != null && ov.steepLon != null
        if (showBadge) {
            val key = "${pal!!.theme}|${dark}|${CarOverlayPainter.gradeText(g!!)}"
            if (key != badgeKey) {
                badgeKey = key
                val bmp: Bitmap = CarOverlayPainter.badgeBitmap(g, pal, density)
                st.addImage(BADGE_IMAGE, bmp)
            }
            st.getSourceAs<GeoJsonSource>(SRC_BADGE)?.setGeoJson(point(ov.steepLat, ov.steepLon))
        } else {
            st.getSourceAs<GeoJsonSource>(SRC_BADGE)?.setGeoJson(CarLink.EMPTY_GEOJSON)
        }
    }

    private fun applyTrip(t: CarTrip) {
        val st = style ?: return
        val showDest = t.phase != "browsing"
        st.getSourceAs<GeoJsonSource>(SRC_DEST)?.setGeoJson(if (showDest) point(t.destinationLat, t.destinationLon) else CarLink.EMPTY_GEOJSON)
        applyDriven(t)
    }

    // ---- the vehicle's marker and the camera that follows it ----------------------------------------------------------------

    private fun sameHeading(a: Double, b: Double): Boolean = a == b || (a.isNaN() && b.isNaN())

    /**
     * The trip's position for the marker. A new position starts a glide to it from wherever the marker is drawn at this
     * moment (also in the middle of the glide before), lasting as long as the time since the position before, capped; or the
     * marker jumps there, when CarMarkerMotion.snaps says a glide would lie. The same position again starts nothing. Returns
     * whether the marker jumped: then the camera is to be put there at once (follow); in a glide the frames carry it.
     */
    private fun moveMarker(t: CarTrip, force: Boolean): Boolean {
        val lat = t.lat
        val lon = t.lon
        if (lat == null || lon == null) {
            glide?.cancel()
            if (hasMarker) posSource?.setGeoJson(CarLink.EMPTY_GEOJSON)
            hasMarker = false
            return false
        }
        val known = CarMarkerMotion.heading(t.heading, lastHeading)
        lastHeading = known
        val heading = known ?: Double.NaN
        val now = SystemClock.elapsedRealtime()
        val phaseChanged = t.phase != markerPhase
        markerPhase = t.phase
        if (hasMarker && !force && !phaseChanged && lat == toLat && lon == toLon && sameHeading(heading, toHeading)) {
            // The same position again (the trip changed in some other way, or the vehicle stands still). While it stands the
            // clock is kept up, so that pulling away is a glide of the last second and not of the whole wait. During a glide
            // it is not: the next position's glide is to last from the position before it, not from this push.
            if (glide?.isRunning != true) lastFixAt = now
            return false
        }
        val gap = now - lastFixAt
        val jump = if (hasMarker) CarMarkerMotion.distanceM(toLat, toLon, lat, lon) else 0.0
        val snap = CarMarkerMotion.snaps(first = !hasMarker, gapMs = gap, jumpM = jump, phaseChanged = phaseChanged, force = force)
        lastFixAt = now
        toLat = lat
        toLon = lon
        toHeading = heading
        if (snap) {
            glide?.cancel()
            hasMarker = true
            drawMarker(lat, lon, heading)
            return true
        }
        fromLat = drawnLat
        fromLon = drawnLon
        fromHeading = drawnHeading
        val a = glide ?: ValueAnimator.ofFloat(0f, 1f).also {
            it.interpolator = LinearInterpolator()
            it.addUpdateListener(onGlideFrame)
            glide = it
        }
        a.cancel()
        a.duration = CarMarkerMotion.durationMs(gap)
        a.start()
        return false
    }

    /** The marker at a place: the position as one point (handed to MapLibre as a point, not as GeoJSON text to read), and the
     * arrow's turn or the dot (showHeading). */
    private fun drawMarker(lat: Double, lon: Double, heading: Double) {
        drawnLat = lat
        drawnLon = lon
        drawnHeading = heading
        val src = posSource ?: return
        showHeading(heading)
        src.setGeoJson(Point.fromLngLat(lon, lat))
    }

    /** A frame's camera: on the marker, where the camera follows the position. Not while the driver has panned away, and not
     * in the route overview or while choosing a route (the camera shows the whole route there, and only the marker glides). */
    private fun glideCamera() {
        val m = map ?: return
        if (!following) return
        val phase = if (overview) "overview" else CarLink.trip.phase
        if (phase == "previewing" || phase == "overview") return
        placeCamera(m, drawnLat, drawnLon, drawnHeading, phase == "guiding", resetZoom = false)
    }

    /** The camera on a position, at once (one camera move; a glide calls this each frame). Close behind the position, turned
     * to the heading and tilted while guiding; north up otherwise, at the zoom the map has (resetZoom: at the starting zoom). */
    private fun placeCamera(m: MapLibreMap, lat: Double, lon: Double, heading: Double, guiding: Boolean, resetZoom: Boolean) {
        val area = stable ?: visible ?: Rect(0, 0, width, height)
        // While guiding the position sits low in the area, so more of the road ahead shows. The overlay's pieces keep clear of
        // that spot (CarOverlayPainter.vehiclePoint works it out from the same area and the same share).
        val extraTop = if (guiding) CarOverlayPainter.guidanceTopInset(area) else 0.0
        val cam = CameraPosition.Builder()
            .target(LatLng(lat, lon))
            .zoom(if (guiding) 16.0 else if (resetZoom) 14.0 else m.cameraPosition.zoom)
            .bearing(if (guiding) (if (heading.isNaN()) m.cameraPosition.bearing else heading) else 0.0)
            .tilt(if (guiding) 45.0 else 0.0)
            .padding(area.left.toDouble(), area.top + extraTop, max(0, width - area.right).toDouble(), max(0, height - area.bottom).toDouble())
            .build()
        m.moveCamera(CameraUpdateFactory.newCameraPosition(cam))
    }

    /** The camera for the phase: the whole route while choosing one, close behind the position and turned to the heading while
     * guiding, the position while looking at the map. Nothing moves while the driver has panned away. While following the
     * position the camera is put on the marker here only when it has to be there at once ([force], or the marker [snapped]):
     * otherwise the glide's frames move it with the marker. */
    private fun follow(force: Boolean, snapped: Boolean = false) {
        val m = map ?: return
        if (!following) return
        val t = CarLink.trip
        val area = stable ?: visible ?: Rect(0, 0, width, height)
        val pad = doubleArrayOf(area.left.toDouble(), area.top.toDouble(), max(0, width - area.right).toDouble(), max(0, height - area.bottom).toDouble())
        val phase = if (overview) "overview" else t.phase
        if (phase == "previewing" || phase == "overview") {
            val b = CarLink.routeBounds
            if (!force && lastCameraPhase == phase) return
            lastCameraPhase = phase
            if (b != null && b.size == 4) {
                // The route's bounds as Dart sends them (MapRoute.bounds): south, west, north, east. North up and flat, said
                // outright: without a bearing and a tilt MapLibre fits the bounds at the camera's present ones, which coming
                // from guidance are the direction of travel and 45 degrees.
                val bounds = LatLngBounds.Builder().include(LatLng(b[0], b[1])).include(LatLng(b[2], b[3])).build()
                m.moveCamera(
                    CameraUpdateFactory.newLatLngBounds(
                        bounds, ROUTE_VIEW_BEARING, ROUTE_VIEW_TILT, pad[0].toInt() + 40, pad[1].toInt() + 40, pad[2].toInt() + 40, pad[3].toInt() + 40,
                    ),
                )
            } else if (t.destinationLat != null && t.destinationLon != null) {
                val cam = CameraPosition.Builder().target(LatLng(t.destinationLat, t.destinationLon)).zoom(13.0)
                    .bearing(ROUTE_VIEW_BEARING).tilt(ROUTE_VIEW_TILT).build()
                m.moveCamera(CameraUpdateFactory.newCameraPosition(cam))
            }
            // Back in guidance the heading and the tilt return with the next placeCamera: leaving the overview and starting
            // a route both come through follow(force = true). The glide does not touch the camera in these two phases
            // (glideCamera), so nothing turns this view back.
            return
        }
        // Where the marker is drawn (in a glide: where it is at this moment); before any marker, the trip's position.
        val lat = if (hasMarker) drawnLat else t.lat ?: return
        val lon = if (hasMarker) drawnLon else t.lon ?: return
        val heading = if (hasMarker) drawnHeading else CarMarkerMotion.heading(t.heading, lastHeading) ?: Double.NaN
        lastCameraPhase = phase
        if (!force && !snapped) return
        placeCamera(m, lat, lon, heading, phase == "guiding", resetZoom = force)
    }

    private fun point(lat: Double?, lon: Double?): String =
        if (lat == null || lon == null) CarLink.EMPTY_GEOJSON
        else "{\"type\":\"FeatureCollection\",\"features\":[{\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[$lon,$lat]},\"properties\":{}}]}"

    private fun releaseMap() {
        styleAttempt++
        main.removeCallbacks(reload)
        // No surface, no map or no session: no glide either.
        glide?.cancel()
        dropStyle()
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
        overlayView?.stop()
        overlayView = null
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
        private const val SRC_DRIVEN = "car-driven-src"
        private const val SRC_BADGE = "car-badge-src"
        private const val BADGE_IMAGE = "car-grade-badge-img"
        private const val ARROW_IMAGE = "car-pos-arrow-img"

        /** The whole-route view (the route overview and the route choice): north up, not tilted. */
        private const val ROUTE_VIEW_BEARING = 0.0
        private const val ROUTE_VIEW_TILT = 0.0

        /** The arrow is turned again when the heading is this many degrees from the turn it has. */
        private const val ROTATE_STEP = 1f
        private val DEFAULT_COLORS = mapOf(
            "route" to "#2f7df6", "routeCasing" to "#0b3a8a", "routeOffroad" to "#d9822b", "routeAlternate" to "#8aa4c8",
            "position" to "#2f7df6", "positionRing" to "#ffffff", "pin" to "#d93a3a",
        )
    }
}
