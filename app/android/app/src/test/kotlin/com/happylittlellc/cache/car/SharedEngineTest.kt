package com.happylittlellc.cache.car

import com.happylittlellc.cache.BuildConfig
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Bug: Settings > Appearance had no Car group when the car started the app. `cache/build` was answered only by the phone's
 * activity, and Dart asks once at start: with no activity the question went unanswered.
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
}
