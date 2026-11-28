package com.happylittlellc.cache.reticulum

internal interface BleAdapterSession {
    val alive: Boolean
    val active: Boolean
    fun stop()
}

/** One platform adapter per Rust handle. Activity recreation does not replace the engine-owned controller. */
internal class BleSessionController(private val open: (Long) -> BleAdapterSession) {
    private data class Running(val handle: Long, val adapter: BleAdapterSession)
    private var current: Running? = null
    private var closed = false

    @Synchronized fun start(handle: Long) {
        check(!closed) { "Bluetooth controller is closed" }
        require(handle > 0) { "A live Bluetooth session is required" }
        val old = current
        if (old?.handle == handle && old.adapter.alive) return
        stop()
        current = Running(handle, open(handle))
    }

    @Synchronized fun stop(expectedHandle: Long? = null) {
        if (expectedHandle != null && current?.handle != expectedHandle) return
        val old = current
        current = null
        old?.adapter?.stop()
    }

    @Synchronized fun close() {
        closed = true
        stop()
    }

    @Synchronized fun snapshot(): Pair<Long?, Boolean> {
        val session = current ?: return null to false
        if (!session.adapter.alive) {
            stop()
            return null to false
        }
        return session.handle to session.adapter.active
    }
}
