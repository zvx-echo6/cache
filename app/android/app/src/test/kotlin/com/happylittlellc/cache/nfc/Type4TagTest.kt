package com.happylittlellc.cache.nfc

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The read-only NFC Forum Type 4 tag (nfc/Type4Tag.kt) and the NDEF message it serves (nfc/LinkNdef.kt), on the JVM. */
class Type4TagTest {
    private val ok = byteArrayOf(0x90.toByte(), 0x00)
    private val notFound = byteArrayOf(0x6A, 0x82.toByte())

    private fun b(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }
    private val selectApp = b(0x00, 0xA4, 0x04, 0x00, 0x07, 0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01, 0x00)
    private val selectCc = b(0x00, 0xA4, 0x00, 0x0C, 0x02, 0xE1, 0x03)
    private val selectNdef = b(0x00, 0xA4, 0x00, 0x0C, 0x02, 0xE1, 0x04)
    private fun read(off: Int, le: Int) = b(0x00, 0xB0, off shr 8, off and 0xFF, le)

    private fun body(r: ByteArray) = r.copyOf(r.size - 2)
    private fun status(r: ByteArray) = r.copyOfRange(r.size - 2, r.size)

    private val link = "cachelink://link/CACHE1-ABCDEFGH234567"
    private val msg = LinkNdef.message(link, "com.happylittlellc.cache")

    @Test fun fullReadSequenceReconstructsTheMessage() {
        val tag = Type4Tag(msg)
        assertArrayEquals(ok, tag.process(selectApp))
        assertArrayEquals(ok, tag.process(selectCc))
        val cc = tag.process(read(0, 15))
        assertArrayEquals(ok, status(cc))
        val c = body(cc)
        assertEquals(15, c.size)
        assertArrayEquals(b(0x00, 0x0F, 0x20, 0x00, 0xFF, 0x00, 0x00), c.copyOf(7))
        assertArrayEquals(b(0x04, 0x06, 0xE1, 0x04), c.copyOfRange(7, 11))
        assertEquals(msg.size + 2, ((c[11].toInt() and 0xFF) shl 8) or (c[12].toInt() and 0xFF))
        assertArrayEquals(b(0x00, 0xFF), c.copyOfRange(13, 15))
        assertArrayEquals(ok, tag.process(selectNdef))
        val nlen = body(tag.process(read(0, 2)))
        assertEquals(msg.size, ((nlen[0].toInt() and 0xFF) shl 8) or (nlen[1].toInt() and 0xFF))
        val out = java.io.ByteArrayOutputStream()
        var off = 2
        while (off < msg.size + 2) {
            val r = tag.process(read(off, 16))
            assertArrayEquals(ok, status(r))
            out.write(body(r))
            off += body(r).size
        }
        assertArrayEquals(msg, out.toByteArray())
    }

    @Test fun aLongMessageReadsInMaxSizeChunks() {
        val long = LinkNdef.message("cachelink://link/" + "A".repeat(1100), "com.happylittlellc.cache.test")
        val tag = Type4Tag(long)
        tag.process(selectApp); tag.process(selectNdef)
        val out = java.io.ByteArrayOutputStream()
        var off = 2
        while (off < long.size + 2) {
            val r = body(tag.process(read(off, 0xFF)))
            assertTrue(r.size in 1..0xFF)
            out.write(r); off += r.size
        }
        assertArrayEquals(long, out.toByteArray())
    }

    @Test fun noCodeSetAnswersNotFound() {
        val tag = Type4Tag(null)
        assertArrayEquals(notFound, tag.process(selectApp))
        assertArrayEquals(notFound, tag.process(selectCc))
        assertArrayEquals(notFound, tag.process(selectNdef))
    }

    @Test fun otherApplicationNotFound() {
        val tag = Type4Tag(msg)
        assertArrayEquals(notFound, tag.process(b(0x00, 0xA4, 0x04, 0x00, 0x07, 0xA0, 0x00, 0x00, 0x00, 0x03, 0x10, 0x10, 0x00)))
    }

    @Test fun filesNeedTheApplicationSelectedFirst() {
        val tag = Type4Tag(msg)
        assertArrayEquals(notFound, tag.process(selectCc))
        assertArrayEquals(b(0x69, 0x85), tag.process(read(0, 2)))
    }

    @Test fun unknownFileNotFound() {
        val tag = Type4Tag(msg)
        tag.process(selectApp)
        assertArrayEquals(notFound, tag.process(b(0x00, 0xA4, 0x00, 0x0C, 0x02, 0x3F, 0x00)))
    }

    @Test fun unknownInstructionsAndClass() {
        val tag = Type4Tag(msg)
        assertArrayEquals(b(0x6D, 0x00), tag.process(b(0x00, 0xCA, 0x00, 0x00, 0x00)))
        assertArrayEquals(b(0x6D, 0x00), tag.process(b(0x00)))
        assertArrayEquals(b(0x6E, 0x00), tag.process(b(0x80, 0xB0, 0x00, 0x00, 0x02)))
    }

    @Test fun writesAreRefused() {
        val tag = Type4Tag(msg)
        tag.process(selectApp); tag.process(selectNdef)
        assertArrayEquals(b(0x69, 0x82), tag.process(b(0x00, 0xD6, 0x00, 0x00, 0x02, 0x00, 0x00)))
    }

    @Test fun readsPastTheEndAndOffsets() {
        val tag = Type4Tag(msg)
        tag.process(selectApp); tag.process(selectNdef)
        val size = msg.size + 2
        // Starting inside, asking for more than is left: only what is left.
        val tail = tag.process(read(size - 3, 0xFF))
        assertArrayEquals(ok, status(tail))
        assertEquals(3, body(tail).size)
        assertEquals(msg.last(), body(tail).last())
        // At the end exactly: nothing, still success. Beyond it: wrong parameters.
        assertEquals(0, body(tag.process(read(size, 4))).size)
        assertArrayEquals(b(0x6B, 0x00), tag.process(read(size + 1, 4)))
        // The offset is two bytes: a high-byte offset reads correctly in a long message.
        val long = LinkNdef.message("cachelink://link/" + "B".repeat(1100), "p")
        val t2 = Type4Tag(long)
        t2.process(selectApp); t2.process(selectNdef)
        val all = java.io.ByteArrayOutputStream()
        var off = 0
        while (off < long.size + 2) { val r = body(t2.process(read(off, 0xFF))); all.write(r); off += r.size }
        assertArrayEquals(long, all.toByteArray().copyOfRange(2, all.size()))
        assertTrue(long.size + 2 > 0x100)
    }

    @Test fun resetForgetsTheSelection() {
        val tag = Type4Tag(msg)
        tag.process(selectApp); tag.process(selectNdef)
        tag.reset()
        assertArrayEquals(b(0x69, 0x85), tag.process(read(0, 2)))
    }

    @Test fun theMessageIsTheUriThenTheApplicationRecord() {
        val m = LinkNdef.message(link, "com.happylittlellc.cache.test")
        // URI record: MB, SR, TNF 1 ("U"), payload = prefix 0 + the URI.
        val uri = link.toByteArray()
        assertEquals(0x91, m[0].toInt() and 0xFF)
        assertEquals(1, m[1].toInt()); assertEquals(uri.size + 1, m[2].toInt() and 0xFF); assertEquals('U'.code, m[3].toInt())
        assertEquals(0, m[4].toInt())
        assertArrayEquals(uri, m.copyOfRange(5, 5 + uri.size))
        // Android Application Record: ME, SR, TNF 4, type "android.com:pkg", payload the package.
        var i = 5 + uri.size
        val pkg = "com.happylittlellc.cache.test".toByteArray()
        assertEquals(0x54, m[i].toInt() and 0xFF)
        assertEquals("android.com:pkg".length, m[i + 1].toInt()); assertEquals(pkg.size, m[i + 2].toInt())
        i += 3
        assertArrayEquals("android.com:pkg".toByteArray(), m.copyOfRange(i, i + 15))
        assertArrayEquals(pkg, m.copyOfRange(i + 15, m.size))
    }
}
