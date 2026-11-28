package com.happylittlellc.cache.reticulum

import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

class GattStateTest {
    private val control = UUID.fromString("37145b00-442d-4a94-917f-8f42c5da28e7")
    private val data = UUID.fromString("37145b00-442d-4a94-917f-8f42c5da28e8")

    @Test fun unrelatedCallbacksCannotReleaseAnOutstandingWrite() {
        val state = GattState()
        val pending = PendingGattOperation(GattOperationKind.ClientWrite, control)
        assertTrue(state.begin(pending))
        assertFalse(state.complete(GattOperationKind.ServerNotify, control))
        assertFalse(state.complete(GattOperationKind.ClientWrite, data))
        assertFalse(state.begin(PendingGattOperation(GattOperationKind.ClientWrite, data)))
        assertTrue(state.complete(GattOperationKind.ClientWrite, control))
        assertTrue(state.begin(PendingGattOperation(GattOperationKind.ClientWrite, data)))
    }

    @Test fun startupTimeoutIsTerminalAndLateCallbacksCannotRestartTheLink() {
        val state = GattState()
        assertTrue(state.beginStartup(100))
        assertTrue(state.beginServiceDiscovery())
        assertFalse(state.expireStartup(1099, 1000))
        assertTrue(state.expireStartup(1100, 1000))
        assertFalse(state.complete(GattOperationKind.ServiceDiscovery))
        assertFalse(state.markReady())
        assertFalse(state.beginServiceDiscovery())
        assertFalse(state.begin(PendingGattOperation(GattOperationKind.ClientWrite, control)))
    }

    @Test fun onlySynchronousRejectionOfTheMatchingOperationMayCancelIt() {
        val state = GattState()
        val pending = PendingGattOperation(GattOperationKind.ClientWrite, control)
        assertTrue(state.begin(pending))
        assertFalse(state.cancel(PendingGattOperation(GattOperationKind.ClientWrite, data)))
        assertFalse(state.begin(PendingGattOperation(GattOperationKind.ClientWrite, data)))
        assertTrue(state.cancel(pending))
        assertTrue(state.begin(PendingGattOperation(GattOperationKind.ClientWrite, data)))
        state.close()
        assertFalse(state.complete(GattOperationKind.ClientWrite, data))
    }
}
