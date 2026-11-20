package com.muisti.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class GlassesHintTest {
    private fun g(link: String = "CONNECTED", hinge: String = "OPEN", don: String = "DONNED", battery: Int = 80, thermal: String = "NONE",
                  compat: String = "COMPATIBLE") = GlassesInfo("Ray-Ban Meta", link, compat, hinge, don, battery, thermal)

    @Test
    fun stuckChannelIsNamedFromSdkState() {
        assertTrue(GlassesHint.describe("REGISTERED", emptyList(), 2_000).contains("looking for"))
        val stuck = GlassesHint.describe("REGISTERED", emptyList(), 15_000)
        assertTrue(stuck, stuck.contains("stuck") && stuck.contains("restart the glasses"))
        assertTrue(GlassesHint.describe("UNAVAILABLE", emptyList(), 15_000).contains("Meta AI isn't available"))
    }

    @Test
    fun deviceStates() {
        assertEquals("Ray-Ban Meta: folded - unfold them", GlassesHint.describe("REGISTERED", listOf(g(hinge = "CLOSED")), 0))
        assertEquals("Ray-Ban Meta: not connected over Bluetooth - check Meta AI (battery 9%)",
            GlassesHint.describe("REGISTERED", listOf(g(link = "DISCONNECTED", battery = 9)), 0))
        assertEquals("Ray-Ban Meta: connected, put them on to start", GlassesHint.describe("REGISTERED", listOf(g(don = "DOFFED")), 0))
        assertEquals("Ray-Ban Meta: connected (glasses are hot)", GlassesHint.describe("REGISTERED", listOf(g(thermal = "SEVERE")), 0))
        assertEquals("Ray-Ban Meta: needs an update in Meta AI", GlassesHint.describe("REGISTERED", listOf(g(compat = "DEVICE_UPDATE_REQUIRED")), 0))
    }
}
