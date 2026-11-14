package com.happylittlellc.cache.nfc

import java.io.ByteArrayOutputStream

/**
 * The NDEF message a device's link is sent as: [a URI record with the link, an Android Application Record naming [pkg]]. The
 * same bytes NdefRecord.createUri and createApplicationRecord give (LinkNdefFrameworkTest checks it); written out here so the
 * tag logic needs no Android class and can be tested on the JVM. The link's scheme is not one of NFC's short prefixes, so the
 * URI record's prefix code is 0 and the whole link follows.
 */
object LinkNdef {
    fun message(uri: String, pkg: String): ByteArray {
        val out = ByteArrayOutputStream()
        val payload = byteArrayOf(0) + uri.toByteArray(Charsets.UTF_8)
        record(out, first = true, last = false, tnf = 0x01, type = "U".toByteArray(), payload = payload)
        record(out, first = false, last = true, tnf = 0x04, type = "android.com:pkg".toByteArray(), payload = pkg.toByteArray(Charsets.UTF_8))
        return out.toByteArray()
    }

    private fun record(out: ByteArrayOutputStream, first: Boolean, last: Boolean, tnf: Int, type: ByteArray, payload: ByteArray) {
        val short = payload.size < 256
        var header = tnf
        if (first) header = header or 0x80
        if (last) header = header or 0x40
        if (short) header = header or 0x10
        out.write(header)
        out.write(type.size)
        if (short) {
            out.write(payload.size)
        } else {
            out.write(payload.size ushr 24); out.write(payload.size ushr 16); out.write(payload.size ushr 8); out.write(payload.size)
        }
        out.write(type)
        out.write(payload)
    }
}
