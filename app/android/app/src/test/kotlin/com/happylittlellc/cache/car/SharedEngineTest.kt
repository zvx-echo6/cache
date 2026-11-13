package com.happylittlellc.cache.car

import android.content.Context
import android.content.Intent
import android.os.Looper
import androidx.car.app.testing.SessionController
import androidx.car.app.testing.TestCarContext
import androidx.lifecycle.Lifecycle
import com.happylittlellc.cache.BuildConfig
import com.happylittlellc.cache.MainActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * The app's engine: what it answers by itself, and its life.
 *
 * Bug: Settings > Appearance had no Car group when the car started the app. `cache/build` was answered only by the phone's
 * activity, and Dart asks once at start: with no activity the question went unanswered.
 *
 * Bug: the engine was destroyed when a car session ended with no phone screen, and when the phone's activity went with no car
 * session. The next car session or phone screen made a new engine and ran the app again in the same process, beside what the
 * old run had left: memory grew with every car session.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class SharedEngineTest {
    /** A messenger with no engine and no activity behind it: only the handlers set on it. */
    private class Messenger : BinaryMessenger {
        val handlers = HashMap<String, BinaryMessenger.BinaryMessageHandler?>()

        override fun send(channel: String, message: ByteBuffer?) {}

        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}

        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            handlers[channel] = handler
        }
    }

    /** Stands in for the Flutter engine: a real one needs Flutter's native library, which a JVM test does not have. */
    private class Engine

    /** Every engine made. */
    private val made = mutableListOf<Engine>()
    private lateinit var life: EngineLife<Engine>
    private lateinit var app: Context

    @Before
    fun setUp() {
        CarLink.reset()
        CarLink.dartForTests = { _, _, done -> done(null) }
        app = RuntimeEnvironment.getApplication()
        made.clear()
        life = EngineLife(make = { Engine().also { e -> made += e } })
    }

    @After
    fun tearDown() = CarLink.reset()

    /** A car session on [on], as Android Auto runs one: created and shown, the first screen up. */
    private fun carConnects(on: EngineLife<Engine> = life): SessionController {
        val car = TestCarContext.createCarContext(app)
        val session = CarSession(startEngine = { on.carStarted(it) }, endEngine = { on.carEnded() })
        val c = SessionController(session, car, Intent())
        car.lifecycleOwner.registry.currentState = Lifecycle.State.CREATED
        c.moveToState(Lifecycle.State.CREATED)
        car.lifecycleOwner.registry.currentState = Lifecycle.State.RESUMED
        c.moveToState(Lifecycle.State.RESUMED)
        shadowOf(Looper.getMainLooper()).idle()
        return c
    }

    private fun carLeaves(c: SessionController) {
        c.moveToState(Lifecycle.State.DESTROYED)
        shadowOf(Looper.getMainLooper()).idle()
    }

    /** The phone screen opens, as MainActivity does it: it says so, then takes the engine. */
    private fun phoneOpens(): Engine {
        life.activityStarted()
        return life.obtain(app)
    }

    private fun phoneCloses() = life.activityEnded()

    @Test
    fun theEngineItselfSaysWhetherTheBuildHasTheCarScreen() {
        val m = Messenger()
        SharedEngine.answerBuild(m)
        val handler = m.handlers["cache/build"]
        assertNotNull(handler)
        val ask = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall("get", null))
        ask.flip()
        var reply: ByteBuffer? = null
        handler!!.onMessage(ask) { reply = it }
        val bytes = reply!!
        bytes.flip()
        val answer = StandardMethodCodec.INSTANCE.decodeEnvelope(bytes) as Map<*, *>
        assertEquals(BuildConfig.CACHE_ANDROID_AUTO, answer["androidAuto"])
    }

    @Test
    fun nothingIsMadeUntilAScreenNeedsIt() {
        assertNull(life.engine)
        assertEquals(0, life.made)
    }

    @Test
    fun theCarConnectingAndLeavingSeveralTimesUsesOneEngine() {
        var first: Engine? = null
        repeat(5) {
            val c = carConnects()
            assertTrue(CarLink.carConnected)
            val e = life.engine
            assertNotNull(e)
            if (first == null) first = e
            assertSame(first, e)
            carLeaves(c)
            assertFalse(CarLink.carConnected)
            // The car has left and no phone screen is open: the engine is still there, the same one.
            assertSame(first, life.engine)
        }
        assertEquals(1, life.made)
        assertEquals(1, made.size)
    }

    @Test
    fun thePhoneScreenComingAndGoingWithNoCarUsesOneEngine() {
        val first = phoneOpens()
        repeat(4) {
            phoneCloses()
            // The activity has gone and there is no car session: the engine is still there, the same one.
            assertSame(first, life.engine)
            assertSame(first, phoneOpens())
        }
        phoneCloses()
        assertSame(first, life.engine)
        assertEquals(1, life.made)
        assertEquals(1, made.size)
    }

    @Test
    fun thePhoneScreenAndTheCarInAnyOrderUseOneEngine() {
        // The car starts Cache with the phone app closed; the phone app opens during the drive.
        val c1 = carConnects()
        val first = life.engine
        assertNotNull(first)
        assertSame(first, phoneOpens())
        // The phone screen goes while the car is connected; the car leaves; the phone screen comes back.
        phoneCloses()
        assertSame(first, life.engine)
        carLeaves(c1)
        assertSame(first, life.engine)
        assertSame(first, phoneOpens())
        // The car connects with the phone screen open and leaves again; then the phone screen goes.
        val c2 = carConnects()
        assertSame(first, life.engine)
        carLeaves(c2)
        phoneCloses()
        assertSame(first, life.engine)
        // With nothing attached at all, a car session and a phone screen still get the same engine.
        val c3 = carConnects()
        assertSame(first, life.engine)
        assertSame(first, phoneOpens())
        carLeaves(c3)
        phoneCloses()
        assertSame(first, life.engine)
        assertEquals(1, life.made)
        assertEquals(1, made.size)
    }

    @Test
    fun aSecondPhoneScreenTakingThePlaceOfTheFirstUsesOneEngine() {
        // Android can make the new activity before the old one is destroyed: the new one starts, then the old lets go.
        val first = phoneOpens()
        assertSame(first, phoneOpens())
        phoneCloses()
        assertSame(first, life.engine)
        phoneCloses()
        assertSame(first, life.engine)
        assertEquals(1, life.made)
    }

    @Test
    fun twoCarSessionsAtOnceUseOneEngine() {
        val first = life.carStarted(app)
        assertSame(first, life.carStarted(app))
        life.carEnded()
        assertSame(first, life.engine)
        life.carEnded()
        assertSame(first, life.engine)
        assertEquals(1, life.made)
    }

    @Test
    fun aCarSessionWhoseEngineCouldNotBeMadeEndsWithoutOne() {
        val failing = EngineLife<Engine>(make = { throw IllegalStateException("no engine") })
        // The session itself still comes up (it logs that the engine could not start) and goes as usual.
        val c = carConnects(failing)
        assertTrue(CarLink.carConnected)
        carLeaves(c)
        assertNull(failing.engine)
        assertEquals(0, failing.made)
    }

    // What made Flutter destroy the engine with the activity: the activity said yes when asked.
    @Test
    fun thePhoneScreenNeverAsksForTheEngineToBeDestroyedWithIt() {
        assertFalse(MainActivity().shouldDestroyEngineWithHost())
    }
}
