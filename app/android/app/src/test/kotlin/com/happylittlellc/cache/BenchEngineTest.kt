package com.happylittlellc.cache

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class BenchEngineTest {
    private val extra = "{\"n_threads\":4}"

    @Test
    fun aBuildThatIsNotTheTestApkIgnoresTheExtraAndNeverReadsTheIntent() {
        var read = false
        assertNull(benchEngineExtra(false) { read = true; extra })
        assertEquals(false, read)
    }

    @Test
    fun theTestApkGivesTheExtra() {
        assertEquals(extra, benchEngineExtra(true) { extra })
    }

    @Test
    fun theTestApkWithNoExtraGivesNull() {
        assertNull(benchEngineExtra(true) { null })
    }
}
