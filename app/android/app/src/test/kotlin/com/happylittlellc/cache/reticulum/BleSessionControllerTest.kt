package com.happylittlellc.cache.reticulum

import org.junit.Assert.*
import org.junit.Test

class BleSessionControllerTest {
    private class Adapter(val id: Long, val events: MutableList<String>) : BleAdapterSession {
        override var alive = true
        override val active get() = alive
        override fun stop() { events.add("stop:$id"); alive = false }
    }

    @Test fun sameHandleIsIdempotentAndNewHandleStopsOldAdapterFirst() {
        val events = mutableListOf<String>()
        val controller = BleSessionController { id -> events.add("start:$id"); Adapter(id, events) }
        controller.start(1)
        controller.start(1)
        controller.start(2)
        assertEquals(listOf("start:1", "stop:1", "start:2"), events)
        assertEquals(2L to true, controller.snapshot())
        controller.stop()
        controller.stop()
        assertEquals(listOf("start:1", "stop:1", "start:2", "stop:2"), events)
    }

    @Test fun failedReplacementDoesNotKeepAStoppedAdapterAsCurrent() {
        val events = mutableListOf<String>()
        val controller = BleSessionController { id ->
            if (id == 2L) error("start failed")
            Adapter(id, events)
        }
        controller.start(1)
        try { controller.start(2); fail("start failure must escape") } catch (_: IllegalStateException) {}
        assertEquals(listOf("stop:1"), events)
        assertEquals(null to false, controller.snapshot())
    }

    @Test fun revokedSessionStopsItsAdapterAndIsNotReportedActive() {
        val events = mutableListOf<String>()
        val adapter = Adapter(1, events)
        val controller = BleSessionController { adapter }
        controller.start(1)
        adapter.alive = false
        assertEquals(null to false, controller.snapshot())
        assertEquals(listOf("stop:1"), events)
    }

    @Test fun lateStartAfterEngineDetachCannotReopenTheRadio() {
        val events = mutableListOf<String>()
        val controller = BleSessionController { id -> events.add("start:$id"); Adapter(id, events) }
        controller.start(1)
        controller.close()
        try { controller.start(2); fail("closed engine must reject late work") } catch (_: IllegalStateException) {}
        assertEquals(listOf("start:1", "stop:1"), events)
        assertEquals(null to false, controller.snapshot())
    }

    @Test fun aLateStopFromThePreviousOwnerCannotCloseItsReplacement() {
        val events = mutableListOf<String>()
        val controller = BleSessionController { id -> events.add("start:$id"); Adapter(id, events) }
        controller.start(1)
        controller.start(2)
        controller.stop(1)
        assertEquals(2L to true, controller.snapshot())
        assertEquals(listOf("start:1", "stop:1", "start:2"), events)
        controller.stop(2)
        assertEquals(null to false, controller.snapshot())
    }
}
