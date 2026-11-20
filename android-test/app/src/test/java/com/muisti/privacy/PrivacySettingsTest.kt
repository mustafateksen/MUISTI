package com.muisti.privacy

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PrivacySettingsTest {
    private class MapStore : KeyValueStore {
        val m = HashMap<String, String>()
        override fun get(key: String) = m[key]
        override fun put(key: String, value: String) { m[key] = value }
    }

    @Test
    fun defaultsAreTheTeamDecision() {
        val s = PrivacySettings()
        assertEquals(setOf("bathroom", "nudity"), s.activeClasses)
        assertFalse("sensitive OCR defaults to off", s.sensitiveOcr)
        assertTrue(s.zones.isEmpty())
    }

    @Test
    fun bathroomAndNudityCannotBeTurnedOff() {
        var s = PrivacySettings().withClass("bathroom", false).withClass("nudity", false)
        assertTrue(s.isActive("bathroom") && s.isActive("nudity"))
        // not even through stored JSON that leaves them out
        s = PrivacySettings.fromJson("""{"active":["pin"],"sensitiveOcr":true}""")
        assertTrue(s.isActive("bathroom") && s.isActive("nudity") && s.isActive("pin"))
        // garbage -> safe defaults
        assertEquals(PrivacySettings(), PrivacySettings.fromJson("{not json"))
    }

    @Test
    fun survivesRestart() {
        val store = MapStore()
        PrivacySettingsRepo(store).update { it.withClass("pin", true).copy(sensitiveOcr = true, zones = listOf(Zone("z1", "Home", 60.17, 24.94, 120.0))) }
        val again = PrivacySettingsRepo(store).current       // a new process reading the same store
        assertTrue(again.isActive("pin")); assertTrue(again.sensitiveOcr)
        assertEquals(1, again.zones.size); assertEquals(120.0, again.zones[0].radiusM, 0.0)
    }

    /** P1.1: toggling a class changes the decision on the same scores, without a rebuild (the ATM photo case). */
    @Test
    fun togglingAClassChangesTheDecision() {
        val atm = mapOf("pin" to 0.82f, "street" to 0.1f, "bathroom" to 0.01f)
        val repo = PrivacySettingsRepo(MapStore())
        assertNull("PIN pads may go to Nemotron by default", SceneRules.blockReason(atm, repo.current))
        repo.update { it.withClass("pin", true) }
        assertNotNull(SceneRules.blockReason(atm, repo.current))
        repo.update { it.withClass("pin", false) }
        assertNull(SceneRules.blockReason(atm, repo.current))
        val toilet = mapOf("bathroom" to 0.9f)
        assertNotNull(SceneRules.blockReason(toilet, repo.update { it.withClass("bathroom", false) }))
    }
}
