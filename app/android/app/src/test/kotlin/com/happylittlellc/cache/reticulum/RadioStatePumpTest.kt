package com.happylittlellc.cache.reticulum

import java.lang.reflect.Proxy
import org.junit.Assert.*
import org.junit.Test

class RadioStatePumpTest {
    private fun bridge(call: (String) -> Any?): BleBridge = Proxy.newProxyInstance(
        BleBridge::class.java.classLoader,
        arrayOf(BleBridge::class.java),
    ) { _, method, _ -> call(method.name) } as BleBridge

    @Test fun revocationAfterRadioOnStopsResourcesBeforeInterruptionEscapes() {
        val applied = mutableListOf<Int>()
        var radioActive = false
        val revoked = InterruptedException("session revoked")
        val native = bridge { method ->
            when (method) {
                "nativeBleWorkGeneration" -> 0L
                "nativeBleDesiredState" -> 3
                "getBLE_RADIO_ENABLED" -> 1
                "nativeBleWakePumps" -> null
                "nativeBleWaitForWork" -> throw revoked
                else -> error("Unexpected bridge call: $method")
            }
        }
        try {
            runRadioStatePump(native, { true }, { radioActive }) { state ->
                applied.add(state)
                radioActive = state != 0
            }
            fail("interruption must reach the outer worker")
        } catch (e: InterruptedException) {
            assertSame(revoked, e)
            assertFalse("radio resources stopped before the worker catches interruption", radioActive)
            assertEquals(listOf(3, 0), applied)
        }
    }

    @Test fun initializationFailureAlsoRunsCleanup() {
        val applied = mutableListOf<Int>()
        val native = bridge { throw IllegalStateException("bridge initialization failed") }
        try {
            runRadioStatePump(native, { true }, { false }, applied::add)
            fail("initialization failure must escape")
        } catch (_: IllegalStateException) {
            assertEquals(listOf(0), applied)
        }
    }

    @Test fun ordinaryStopClosesRadioWithoutAnotherNativeWait() {
        val applied = mutableListOf<Int>()
        val native = bridge { method ->
            if (method == "nativeBleWorkGeneration") 0L else error("Unexpected bridge call: $method")
        }
        runRadioStatePump(native, { false }, { false }, applied::add)
        assertEquals(listOf(0), applied)
    }
}
