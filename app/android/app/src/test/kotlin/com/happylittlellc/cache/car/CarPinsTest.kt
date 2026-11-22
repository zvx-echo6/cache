package com.happylittlellc.cache.car

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.ByteArrayOutputStream

/**
 * The phone map's pins on the car's map (CarPins): what the `pins` message leaves in hand, and what the car's style is given from
 * it. The style itself is a stand-in (MapLibre does not run in a JVM test): it records the source it is given and the pictures.
 * SAMPLE DATA: made-up coordinates and picture names.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class CarPinsTest {
    /** The car style's stand-in. */
    private class FakeStyle : CarPins.Target {
        val sources = mutableMapOf<String, String>()
        val images = mutableMapOf<String, Bitmap>()
        var imageAdds = 0

        override fun setSource(id: String, geojson: String) {
            sources[id] = geojson
        }

        override fun addImage(name: String, bitmap: Bitmap) {
            images[name] = bitmap
            imageAdds++
        }
    }

    private var heard = 0
    private val listener = object : CarLink.Listener {
        override fun onPins() {
            heard++
        }
    }

    @Before
    fun setUp() {
        CarLink.reset()
        CarLink.addListener(listener)
        heard = 0
    }

    @After
    fun tearDown() = CarLink.reset()

    private fun push(method: String, args: Any?) {
        CarLink.handle(MethodCall(method, args), object : MethodChannel.Result {
            override fun success(result: Any?) {}
            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}
            override fun notImplemented() {}
        })
    }

    /** A picture as Dart sends it: a PNG of [px] pixels square (the phone draws a 30-point pin in a 45-point box, at 3 per point). */
    private fun png(px: Int = 135, color: Int = Color.rgb(63, 191, 174)): ByteArray {
        val bmp = Bitmap.createBitmap(px, px, Bitmap.Config.ARGB_8888)
        Canvas(bmp).drawColor(color)
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
        return out.toByteArray()
    }

    private val geo = "{\"type\":\"FeatureCollection\",\"features\":[" +
        "{\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[-115.21,43.11]},\"properties\":{\"pin\":\"pin-icon-radio_tower-ae86f0\"}}," +
        "{\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[-115.1,43.2]},\"properties\":{\"pin\":\"pin-icon-star-3fbfae\"}}]}"

    private fun message(images: Map<String, ByteArray>, reset: Boolean, geojson: String = geo) = mapOf<String, Any?>(
        "source" to "cache-notebook", "geojson" to geojson, "images" to images, "ratio" to 3.0, "reset" to reset,
    )

    @Test
    fun thePinsMessageFillsThePinSourceAndRegistersEachPicture() {
        push("pins", message(mapOf("pin-icon-radio_tower-ae86f0" to png(), "pin-icon-star-3fbfae" to png()), reset = true))
        assertEquals(1, heard)
        assertEquals("cache-notebook", CarPins.source)
        assertEquals(geo, CarPins.geoJson)
        assertEquals(setOf("pin-icon-radio_tower-ae86f0", "pin-icon-star-3fbfae"), CarPins.imageNames)

        val style = FakeStyle()
        val have = HashSet<String>()
        CarPins.applyTo(style, have)
        assertEquals(geo, style.sources["cache-notebook"])
        assertEquals(setOf("pin-icon-radio_tower-ae86f0", "pin-icon-star-3fbfae"), style.images.keys)
        // The same style again (the pins changed, the pictures did not): only the source.
        CarPins.applyTo(style, have)
        assertEquals(2, style.imageAdds)
    }

    @Test
    fun eachPictureSaysItIsDrawnAtThreePixelsPerPointSoItShowsAtThePhonesSizeInPoints() {
        push("pins", message(mapOf("pin-icon-star-3fbfae" to png(135)), reset = true))
        val held = CarPins.image("pin-icon-star-3fbfae")
        assertNotNull(held)
        val bmp = held!!
        // MapLibre shows an added bitmap at density / 160 pixels per point: 135 px at 3 per point is the phone's 45-point box,
        // whatever the car screen's own density (a bitmap decoded here would otherwise carry the phone's).
        assertEquals(480, bmp.density)
        assertEquals(45f, bmp.width / (bmp.density / 160f), 0.001f)
    }

    @Test
    fun laterMessagesAddOnlyNewPicturesAndAResetDropsTheOldOnes() {
        push("pins", message(mapOf("pin-icon-star-3fbfae" to png()), reset = true))
        val moved = geo.replace("43.2", "43.3")
        push("pins", message(emptyMap(), reset = false, geojson = moved))
        assertEquals(setOf("pin-icon-star-3fbfae"), CarPins.imageNames)
        assertEquals(moved, CarPins.geoJson)
        push("pins", message(mapOf("pin-teardrop-star-3fbfae" to png()), reset = true))
        assertEquals(setOf("pin-teardrop-star-3fbfae"), CarPins.imageNames)
        assertEquals(3, heard)
    }

    @Test
    fun aNewStyleGetsEveryPictureAndThePinsAtOnce() {
        push("pins", message(mapOf("pin-icon-radio_tower-ae86f0" to png(), "pin-icon-star-3fbfae" to png()), reset = true))
        CarPins.applyTo(FakeStyle(), HashSet())
        // Day to night: the renderer's new style starts with no pictures (dropStyle clears its set).
        val night = FakeStyle()
        CarPins.applyTo(night, HashSet())
        assertEquals(2, night.images.size)
        assertEquals(geo, night.sources["cache-notebook"])
    }

    @Test
    fun theCarGoingAwayDropsThePins() {
        push("pins", message(mapOf("pin-icon-star-3fbfae" to png()), reset = true))
        CarLink.setCarConnected(false)
        assertEquals(CarLink.EMPTY_GEOJSON, CarPins.geoJson)
        assertTrue(CarPins.imageNames.isEmpty())
        val style = FakeStyle()
        CarPins.applyTo(style, HashSet())
        assertEquals(CarLink.EMPTY_GEOJSON, style.sources["cache-notebook"])
    }

    @Test
    fun aPictureThatIsNotAnImageIsLeftOutAndTheRestStillCome() {
        push("pins", message(mapOf("broken" to byteArrayOf(1, 2, 3), "pin-icon-star-3fbfae" to png()), reset = true))
        assertEquals(setOf("pin-icon-star-3fbfae"), CarPins.imageNames)
        assertEquals(geo, CarPins.geoJson)
    }
}
