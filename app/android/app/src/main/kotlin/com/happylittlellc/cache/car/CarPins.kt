package com.happylittlellc.cache.car

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import kotlin.math.roundToInt

/**
 * The phone map's pins on the car's map: the places of the notebooks on the phone's map (saved places among them) and the shown
 * repeater lists' repeaters, as lib/car/car_pins.dart sends them (`pins`).
 *
 * The car's style is the phone's style, which already has the pins' source (`cache-notebook`) and its symbol layer, with the
 * layer's icon size and anchor for the person's pin style; the layer draws per feature the picture its `pin` names. So the car
 * fills that source and adds the pictures, and nothing else: the layer sits where the phone's style has it, under everything the
 * car adds on top of the style (the route, the destination, the grade badge, the vehicle), and the car's own cards are a View
 * above the whole map. The car's map takes no taps, so the pins do nothing when touched.
 *
 * The pictures are PNGs drawn by the phone's own pin painter (pin_image.dart) at [ratio] pixels per point. MapLibre shows an
 * added bitmap at the scale its density says (density / 160), and a bitmap decoded here would say the phone's own: each one is
 * given the density of the ratio it was drawn at, so it shows as many points wide as on the phone (as CarOverlayPainter does for
 * the badge and the arrow).
 *
 * Held here (not in the map) so that a style the car loads again (day and night, a theme, the pin style) gets them at once.
 * Coordinates and pictures only: nothing of a place's name comes across, and nothing here is logged. Main thread only.
 */
object CarPins {
    const val DEFAULT_SOURCE = "cache-notebook"
    const val DEFAULT_RATIO = 3f

    /** Where the map takes them: the style's source and its pictures (CarMapRenderer gives the present style). */
    interface Target {
        fun setSource(id: String, geojson: String)
        fun addImage(name: String, bitmap: Bitmap)
    }

    var source: String = DEFAULT_SOURCE
        private set
    var geoJson: String = CarLink.EMPTY_GEOJSON
        private set
    private val images = LinkedHashMap<String, Bitmap>()

    /** The names of the pictures held. */
    val imageNames: Set<String> get() = images.keys.toSet()

    fun image(name: String): Bitmap? = images[name]

    /** Dart's `pins` message: the pins, and the pictures not sent before in this connection ([reset]: drop the ones held first). */
    fun receive(args: Map<*, *>) {
        if (args["reset"] == true) images.clear()
        (args["source"] as? String)?.takeIf { it.isNotEmpty() }?.let { source = it }
        val ratio = (args["ratio"] as? Number)?.toFloat()?.takeIf { it > 0f } ?: DEFAULT_RATIO
        (args["images"] as? Map<*, *>)?.forEach { (k, v) ->
            val name = k as? String ?: return@forEach
            val bytes = v as? ByteArray ?: return@forEach
            val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return@forEach
            bmp.density = (160f * ratio).roundToInt()
            images[name] = bmp
        }
        geoJson = args["geojson"] as? String ?: CarLink.EMPTY_GEOJSON
    }

    /** Gives [t] the pins and the pictures it does not have yet ([have]: the names the present style has; filled in here). */
    fun applyTo(t: Target, have: MutableSet<String>) {
        for ((name, bmp) in images) {
            if (have.add(name)) t.addImage(name, bmp)
        }
        t.setSource(source, geoJson)
    }

    /** The car went away (or the tests start again): no pins and no pictures until the phone sends them again. */
    fun clear() {
        images.clear()
        source = DEFAULT_SOURCE
        geoJson = CarLink.EMPTY_GEOJSON
    }
}
