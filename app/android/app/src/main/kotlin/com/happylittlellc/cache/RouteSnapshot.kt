package com.happylittlellc.cache

import android.content.Context
import android.graphics.Bitmap
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.maps.Style
import org.maplibre.android.snapshotter.MapSnapshotter
import java.nio.ByteBuffer

/**
 * The whole-route picture during guidance (lib/nav/overview/route_overview.dart): MapLibre's offscreen map snapshotter renders
 * the app's map style, with the route written into it, at a fixed camera, once per route, size and theme. It reads the same tile
 * server on 127.0.0.1 as the live map, which it never touches.
 *
 * "render" takes {style (JSON), lat, lon, zoom, width, height (logical pixels), pixelRatio} and answers {rgba (the pixels, row by
 * row), width, height (device pixels), ms (the render alone)}. A newer request cancels one still running, which answers
 * "cancelled".
 */
class RouteSnapshot(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "co.cache/route_snapshot")
    private var active: MapSnapshotter? = null
    private var activeResult: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "render" -> render(call, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun render(call: MethodCall, result: MethodChannel.Result) {
        val style = call.argument<String>("style")
        val lat = call.argument<Number>("lat")?.toDouble()
        val lon = call.argument<Number>("lon")?.toDouble()
        val zoom = call.argument<Number>("zoom")?.toDouble()
        val width = call.argument<Number>("width")?.toInt() ?: 0
        val height = call.argument<Number>("height")?.toInt() ?: 0
        val ratio = call.argument<Number>("pixelRatio")?.toFloat() ?: 1f
        if (style == null || lat == null || lon == null || zoom == null || width <= 0 || height <= 0) {
            result.error("bad_args", "style, lat, lon, zoom, width and height are needed", null)
            return
        }
        cancel()
        MapLibre.getInstance(context)
        val camera = CameraPosition.Builder().target(LatLng(lat, lon)).zoom(zoom).bearing(0.0).tilt(0.0).build()
        val options = MapSnapshotter.Options(width, height)
            .withStyleBuilder(Style.Builder().fromJson(style))
            .withCameraPosition(camera)
            .withPixelRatio(ratio)
            .withLogo(false)
        val snapshotter = MapSnapshotter(context, options)
        active = snapshotter
        activeResult = result
        val started = SystemClock.elapsedRealtimeNanos()
        snapshotter.start({ snapshot ->
            if (active !== snapshotter) return@start
            val ms = (SystemClock.elapsedRealtimeNanos() - started) / 1e6
            active = null
            activeResult = null
            val bitmap = snapshot.bitmap
            // ARGB_8888 is held as R, G, B, A bytes, which Flutter reads as rgba8888 (the picture is opaque).
            val rgba = if (bitmap.config == Bitmap.Config.ARGB_8888) bitmap else bitmap.copy(Bitmap.Config.ARGB_8888, false)
            val buffer = ByteBuffer.allocate(rgba.byteCount)
            rgba.copyPixelsToBuffer(buffer)
            if (rgba !== bitmap) rgba.recycle()
            result.success(mapOf("rgba" to buffer.array(), "width" to bitmap.width, "height" to bitmap.height, "ms" to ms))
        }, { error ->
            if (active !== snapshotter) return@start
            active = null
            activeResult = null
            result.error("snapshot", error, null)
        })
    }

    private fun cancel() {
        active?.cancel()
        active = null
        activeResult?.error("cancelled", "a newer picture was asked for", null)
        activeResult = null
    }

    fun dispose() {
        cancel()
        channel.setMethodCallHandler(null)
    }
}
