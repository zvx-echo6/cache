package com.happylittlellc.cache.nfc

import android.nfc.cardemulation.HostApduService
import android.os.Bundle

/** A read-only NFC Forum Type 4 tag holding the link LinkTag serves (see Type4Tag). */
class LinkTagService : HostApduService() {
    private var tag: Type4Tag? = null

    override fun processCommandApdu(commandApdu: ByteArray?, extras: Bundle?): ByteArray {
        if (commandApdu == null) return byteArrayOf(0x6D, 0x00)
        // A new connection starts with SELECT of the application; the message is taken then, so it is whatever is current.
        var t = tag
        if (t == null || commandApdu.size > 1 && commandApdu[1] == 0xA4.toByte() && commandApdu.size > 2 && commandApdu[2] == 0x04.toByte()) {
            t = Type4Tag(LinkTag.message)
            tag = t
        }
        return t.process(commandApdu)
    }

    override fun onDeactivated(reason: Int) {
        tag = null
    }
}
