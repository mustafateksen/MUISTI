package com.muisti.privacy

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OldMemoryScanTest {
    private class MapStore : KeyValueStore {
        val m = HashMap<String, String>()
        override fun get(key: String) = m[key]
        override fun put(key: String, value: String) { m[key] = value }
    }

    /** 1..1100 stored frames; the old toilet frames of the test phone are private. */
    private class Frames : ScanTarget {
        val frames = (1..1100).associateWith { id -> byteArrayOf(if (id in PRIVATE) 1 else 0) }.toMutableMap()
        val checked = ArrayList<Int>()
        override fun frameIds() = frames.keys.sorted()
        override fun frameBytes(id: Int) = frames[id]?.also { checked.add(id) }
        override fun deleteFrames(ids: Set<Int>) = ids.count { frames.remove(it) != null }
    }

    companion object { val PRIVATE = (845..852).toSet() + setOf(915, 1006, 1029) }

    @Test
    fun killedMidScanContinuesFromTheSavedId() {
        val store = MapStore()
        val frames = Frames()
        // first run: the app is killed after 900 checks
        var n = 0
        val first = OldMemoryScan(PrivacySettingsRepo(store), frames, { it[0] == 1.toByte() }).run(shouldStop = { ++n > 900 })
        assertFalse(first.done)
        assertEquals(900, first.lastScannedId)
        val checkedBefore = frames.checked.size

        // a new process: settings read back from the store, the scan continues after id 900 (not from zero)
        val repo2 = PrivacySettingsRepo(store)
        assertEquals(900, repo2.current.scan.lastScannedId)
        frames.checked.clear()
        val second = OldMemoryScan(repo2, frames, { it[0] == 1.toByte() }).run()
        assertTrue(second.done)
        assertTrue("resumed after 900", frames.checked.min() > 900)
        assertEquals(1100 - 900, frames.checked.size)
        assertEquals(900, checkedBefore)

        // frames 845-852, 915, 1006, 1029 are gone, nothing else
        assertTrue(PRIVATE.none { it in frames.frames })
        assertEquals(1100 - PRIVATE.size, frames.frames.size)
        assertEquals(PRIVATE.size, second.removed)

        // done stays done: a later start checks nothing
        frames.checked.clear()
        OldMemoryScan(PrivacySettingsRepo(store), frames, { true }).run()
        assertTrue(frames.checked.isEmpty())
    }

    @Test
    fun aCrashingCheckCountsAsPrivate() {
        val frames = Frames()
        val st = OldMemoryScan(PrivacySettingsRepo(MapStore()), frames, { if (it[0] == 1.toByte()) error("model crashed") else false }).run()
        assertTrue(st.done)
        assertEquals(PRIVATE.size, st.removed)
    }

    @Test
    fun switchingOnAClassRestartsTheScan() {
        val s = PrivacySettings(scan = ScanStatus(1100, 1100, 3, true))
        assertEquals(ScanStatus(), OldMemoryScan.restart(s.withClass("pin", true)).scan)
    }
}
