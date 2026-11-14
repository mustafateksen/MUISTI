package com.muisti.privacy

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ZonesTest {
    private val home = Zone("h", "Home", 60.169900, 24.938400, 150.0)

    @Test
    fun distance() {
        // Helsinki railway station -> Kamppi metro: ~560 m
        val d = Zones.distanceM(60.17146, 24.94121, 60.16867, 24.93123)
        assertEquals(600.0, d, 60.0)
        assertEquals(0.0, Zones.distanceM(1.0, 2.0, 1.0, 2.0), 1e-6)
    }

    @Test
    fun pointInZone() {
        assertEquals(home, Zones.inside(60.1699, 24.9384, 5f, listOf(home)))                 // centre
        assertEquals(home, Zones.inside(60.1699 + 0.0012, 24.9384, 5f, listOf(home)))         // ~133 m north
        assertNull(Zones.inside(60.1699 + 0.0020, 24.9384, 5f, listOf(home)))                 // ~222 m
        assertEquals("rough fix reaching the zone counts as inside", home, Zones.inside(60.1699 + 0.0020, 24.9384, 90f, listOf(home)))
        assertNull("accuracy is capped at 100 m", Zones.inside(60.1699 + 0.0040, 24.9384, 5000f, listOf(home)))
        assertNull(Zones.inside(60.1699, 24.9384, 5f, emptyList()))
    }

    @Test
    fun radiusIsClamped() {
        assertEquals(30.0, Zones.newZone("x", 0.0, 0.0, 1.0).radiusM, 0.0)
        assertEquals(2000.0, Zones.newZone("x", 0.0, 0.0, 1e6).radiusM, 0.0)
    }
}
