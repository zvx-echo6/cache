package com.happylittlellc.cache.reticulum

/** The real radio worker loop, separated from Android objects so revocation and shutdown ordering can be exercised on JVM. */
internal fun runRadioStatePump(
    bridge: BleBridge,
    running: () -> Boolean,
    active: () -> Boolean,
    applyState: (Int) -> Unit,
) {
    try {
        var lastState = Int.MIN_VALUE
        var generation = bridge.nativeBleWorkGeneration()
        while (running()) {
            val state = bridge.nativeBleDesiredState()
            val wantsRadio = (state and bridge.BLE_RADIO_ENABLED) != 0
            if (state != lastState || wantsRadio && !active()) {
                val wasActive = active()
                applyState(state)
                lastState = state
                if (!wasActive && active()) bridge.nativeBleWakePumps()
            }
            generation = bridge.nativeBleWaitForWork(generation, 1_000L)
        }
    } finally {
        // Revocation throws InterruptedException from JNI. Cleanup must happen before the outer worker catches it.
        applyState(0)
    }
}
