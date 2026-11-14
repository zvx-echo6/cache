package com.happylittlellc.cache.nfc

/**
 * A read-only NFC Forum Type 4 tag holding one NDEF message, as ISO 7816-4 commands see it (NFC Forum Type 4 Tag Operation
 * Specification, version 2.0). No Android class is used, so it is tested on the JVM. [process] answers one command APDU.
 *
 * With no message ([ndefMessage] null) the NDEF application is not found, so nothing can be read. One instance is one
 * connection: [reset] forgets what was selected.
 */
class Type4Tag(ndefMessage: ByteArray?) {
    private enum class Selected { NONE, APP, CC, NDEF }

    private var selected = Selected.NONE
    private var appSelected = false
    private val ndefFile: ByteArray? = ndefMessage?.let { byteArrayOf((it.size ushr 8).toByte(), it.size.toByte()) + it }
    private val ccFile: ByteArray? = ndefFile?.let { cc(it.size) }

    fun reset() {
        selected = Selected.NONE
        appSelected = false
    }

    fun process(apdu: ByteArray): ByteArray {
        if (apdu.size < 4) return NOT_SUPPORTED
        val cla = apdu[0].toInt() and 0xFF
        val ins = apdu[1].toInt() and 0xFF
        val p1 = apdu[2].toInt() and 0xFF
        val p2 = apdu[3].toInt() and 0xFF
        if (cla != 0x00) return CLA_NOT_SUPPORTED
        return when (ins) {
            0xA4 -> select(p1, p2, apdu)
            0xB0 -> read(p1, p2, apdu)
            0xD6, 0xD7 -> SECURITY  // update binary: the tag is read-only
            else -> NOT_SUPPORTED
        }
    }

    private fun select(p1: Int, p2: Int, apdu: ByteArray): ByteArray {
        val lc = if (apdu.size > 4) apdu[4].toInt() and 0xFF else 0
        if (apdu.size < 5 + lc) return WRONG_LENGTH
        val data = apdu.copyOfRange(5, 5 + lc)
        when (p1) {
            0x04 -> {
                if (ndefFile == null || !data.contentEquals(AID)) return NOT_FOUND
                appSelected = true
                selected = Selected.APP
                return OK
            }
            0x00 -> {
                if (!appSelected || ndefFile == null || data.size != 2) return NOT_FOUND
                val id = ((data[0].toInt() and 0xFF) shl 8) or (data[1].toInt() and 0xFF)
                selected = when (id) {
                    0xE103 -> Selected.CC
                    0xE104 -> Selected.NDEF
                    else -> return NOT_FOUND
                }
                return OK
            }
            else -> return BAD_P1P2
        }
    }

    private fun read(p1: Int, p2: Int, apdu: ByteArray): ByteArray {
        val file = when (selected) {
            Selected.CC -> ccFile
            Selected.NDEF -> ndefFile
            else -> null
        } ?: return CONDITIONS
        if ((p1 and 0x80) != 0) return BAD_P1P2  // a short file id in P1: not used
        val offset = (p1 shl 8) or p2
        if (offset > file.size) return WRONG_PARAMS
        var le = if (apdu.size > 4) apdu[4].toInt() and 0xFF else 0
        if (le == 0) le = MLE
        le = minOf(le, MLE)
        val end = minOf(file.size, offset + le)
        return file.copyOfRange(offset, end) + OK
    }

    companion object {
        /** The NFC Forum NDEF Tag Application (version 2). */
        val AID = byteArrayOf(0xD2.toByte(), 0x76, 0x00, 0x00, 0x85.toByte(), 0x01, 0x01)

        /** The most one read returns (MLe in the capability container). */
        const val MLE = 0xFF

        private val OK = byteArrayOf(0x90.toByte(), 0x00)
        private val NOT_FOUND = byteArrayOf(0x6A, 0x82.toByte())
        private val BAD_P1P2 = byteArrayOf(0x6A, 0x86.toByte())
        private val WRONG_PARAMS = byteArrayOf(0x6B, 0x00)
        private val WRONG_LENGTH = byteArrayOf(0x67, 0x00)
        private val NOT_SUPPORTED = byteArrayOf(0x6D, 0x00)
        private val CLA_NOT_SUPPORTED = byteArrayOf(0x6E, 0x00)
        private val CONDITIONS = byteArrayOf(0x69, 0x85.toByte())
        private val SECURITY = byteArrayOf(0x69, 0x82.toByte())

        /** The capability container: length, mapping 2.0, MLe, MLc 0 (no writes), the NDEF file control TLV (read open, write never). */
        private fun cc(ndefFileSize: Int): ByteArray = byteArrayOf(
            0x00, 0x0F, 0x20, 0x00, MLE.toByte(), 0x00, 0x00,
            0x04, 0x06, 0xE1.toByte(), 0x04, (ndefFileSize ushr 8).toByte(), ndefFileSize.toByte(), 0x00, 0xFF.toByte(),
        )
    }
}
