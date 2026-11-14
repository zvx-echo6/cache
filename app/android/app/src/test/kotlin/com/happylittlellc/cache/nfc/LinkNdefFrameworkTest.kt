package com.happylittlellc.cache.nfc

import android.nfc.NdefMessage
import android.nfc.NdefRecord
import org.junit.Assert.assertArrayEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** LinkNdef writes the same bytes the Android framework does for [URI record, Application Record]. */
@RunWith(RobolectricTestRunner::class)
class LinkNdefFrameworkTest {
    @Test fun sameBytesAsTheFramework() {
        for (uri in listOf("cachelink://link/CACHE1-ABC234", "cachelink://link/" + "Q".repeat(1100))) {
            for (pkg in listOf("com.happylittlellc.cache", "com.happylittlellc.cache.test")) {
                val expect = NdefMessage(NdefRecord.createUri(uri), NdefRecord.createApplicationRecord(pkg)).toByteArray()
                assertArrayEquals(expect, LinkNdef.message(uri, pkg))
            }
        }
    }
}
