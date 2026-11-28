package com.happylittlellc.cache.reticulum

import java.nio.ByteBuffer

/** The adapter boundary is injectable in JVM tests; an instance belongs to exactly one Rust BLE session. */
interface BleBridge {
    val BLE_RADIO_ENABLED: Int get() = 0x01
    val BLE_RADIO_ADVERTISING: Int get() = 0x02
    val BLE_RADIO_SCANNING: Int get() = 0x04
    val BLE_INGRESS_ACCEPTED: Int get() = 0
    val BLE_INGRESS_FULL: Int get() = 1
    val BLE_INGRESS_CLOSED: Int get() = 2

    fun nativeBleSetPsm(psm: Int)
    fun nativeBleDesiredState(): Int
    fun nativeBlePeerCapacity(): Int
    fun nativeBleWorkGeneration(): Long
    @Throws(InterruptedException::class)
    fun nativeBleWaitForWork(observed: Long, timeoutMillis: Long): Long
    fun nativeBleWakePumps()
    fun nativeBleIdentity(buffer: ByteBuffer): Int
    fun nativeBleSighting(address: ByteBuffer, rssi: Int)
    fun nativeBleDialFailed(address: ByteBuffer): Boolean
    fun nativeBleLinkUp(connId: Int, address: ByteBuffer, rssi: Int, dialed: Boolean): Boolean
    fun nativeBleColumbaLinkUp(connId: Int, address: ByteBuffer, rssi: Int, dialed: Boolean, peerIdentity: ByteBuffer): Boolean
    fun nativeBleControlIn(connId: Int, buffer: ByteBuffer, len: Int): Int
    fun nativeBleControlOut(connId: Int, buffer: ByteBuffer): Int
    fun nativeBleCommitControlOut(connId: Int): Boolean
    fun nativeBleL2capIn(connId: Int, buffer: ByteBuffer, len: Int): Boolean
    fun nativeBleL2capOut(connId: Int, buffer: ByteBuffer): Int
    fun nativeBleDataIn(connId: Int, buffer: ByteBuffer, len: Int): Int
    fun nativeBleDataOut(connId: Int, buffer: ByteBuffer): Int
    fun nativeBleCommitDataOut(connId: Int): Boolean
    fun nativeBleL2capUp(connId: Int)
    fun nativeBleDisconnected(connId: Int)
    fun nativeBleNextClose(): Int
    fun nativeBleNextDial(buffer: ByteBuffer): Boolean
    fun nativeBleNextL2capOpen(buffer: ByteBuffer): Boolean
}

/** JNI reads [handle] on every callback. Closing that Rust session revokes it, including callbacks already queued by Android. */
class NativeBridge(@JvmField val handle: Long) : BleBridge {
    init {
        require(handle > 0) { "A live Bluetooth session is required" }
        System.loadLibrary("cache_search")
    }

    override external fun nativeBleSetPsm(psm: Int)
    override external fun nativeBleDesiredState(): Int
    override external fun nativeBlePeerCapacity(): Int
    override external fun nativeBleWorkGeneration(): Long
    @Throws(InterruptedException::class)
    override external fun nativeBleWaitForWork(observed: Long, timeoutMillis: Long): Long
    override external fun nativeBleWakePumps()
    override external fun nativeBleIdentity(buffer: ByteBuffer): Int
    override external fun nativeBleSighting(address: ByteBuffer, rssi: Int)
    override external fun nativeBleDialFailed(address: ByteBuffer): Boolean
    override external fun nativeBleLinkUp(connId: Int, address: ByteBuffer, rssi: Int, dialed: Boolean): Boolean
    override external fun nativeBleColumbaLinkUp(connId: Int, address: ByteBuffer, rssi: Int, dialed: Boolean, peerIdentity: ByteBuffer): Boolean
    override external fun nativeBleControlIn(connId: Int, buffer: ByteBuffer, len: Int): Int
    override external fun nativeBleControlOut(connId: Int, buffer: ByteBuffer): Int
    override external fun nativeBleCommitControlOut(connId: Int): Boolean
    override external fun nativeBleL2capIn(connId: Int, buffer: ByteBuffer, len: Int): Boolean
    override external fun nativeBleL2capOut(connId: Int, buffer: ByteBuffer): Int
    override external fun nativeBleDataIn(connId: Int, buffer: ByteBuffer, len: Int): Int
    override external fun nativeBleDataOut(connId: Int, buffer: ByteBuffer): Int
    override external fun nativeBleCommitDataOut(connId: Int): Boolean
    override external fun nativeBleL2capUp(connId: Int)
    override external fun nativeBleDisconnected(connId: Int)
    override external fun nativeBleNextClose(): Int
    override external fun nativeBleNextDial(buffer: ByteBuffer): Boolean
    override external fun nativeBleNextL2capOpen(buffer: ByteBuffer): Boolean
}
