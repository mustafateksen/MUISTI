package com.muisti.engine

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

class EpisodesTest {
    private fun check(eps: List<Episode>, sightings: List<JSONObject>) {
        val all = eps.flatMap { it.members }
        assertEquals("no sighting in two episodes", all.size, all.toSet().size)
        assertEquals("every sighting in an episode", sightings.map { Episodes.key(it) }.toSet(), all.toSet())
        for (e in eps) { assertTrue(e.start <= e.end); assertTrue(e.keyFrames.all { it in e.members }); assertTrue(e.keyFrames.size in 1..4) }
        assertTrue("episodes do not overlap", eps.zipWithNext().all { (a, b) -> a.end <= b.start })
    }

    @Test
    fun fixtureDay() {
        val s = Fixture.sightings()
        val eps = Episodes.group(s)
        check(eps, s)
        // home, street, office, wet-floor corridor (28 min later), lunch, pharmacy, supermarket
        assertEquals(listOf(3, 3, 3, 1, 1, 1, 3), eps.map { it.members.size })
        assertEquals("Mannerheimintie, Kamppi", eps[0].place)
        assertTrue(eps[6].names.contains("K-Market Annankatu"))
        // stable: shuffled input, same episodes; ids do not depend on order
        assertEquals(eps, Episodes.group(s.shuffled(java.util.Random(7))))
        // a later sighting does not change the earlier, closed episodes
        val later = JSONObject(s.last().toString()).put("seen_at", s.last().getLong("seen_at") + 3 * 3600_000L).put("evidence_frame", "99.jpg")
        assertEquals(eps, Episodes.group(s + later).dropLast(1))
    }

    @Test
    fun moveSplitsEvenWithoutAGap() {
        fun at(t: Long, lat: Double) = JSONObject().put("seen_at", t).put("evidence_frame", "$t.jpg").put("lat", lat).put("lon", 24.9)
        val eps = Episodes.group(listOf(at(0, 60.0), at(60_000, 60.0005), at(120_000, 60.01)))   // ~1.1 km jump
        assertEquals(listOf(2, 1), eps.map { it.members.size })
    }

    @Test
    fun noLocationSceneChangeAfterAPause() {
        fun at(t: Long, place: String) = JSONObject().put("seen_at", t).put("evidence_frame", "$t.jpg").put("scene", JSONObject().put("place_type", place))
        val eps = Episodes.group(listOf(at(0, "kitchen"), at(60_000, "living room"), at(7 * 60_000, "supermarket")))
        assertEquals(listOf(2, 1), eps.map { it.members.size })
    }

    /** The real video memories, when this machine has them (nemotron/results/<video>/v21z). */
    @Test
    fun videoMemories() {
        val nem = File(File(System.getProperty("muisti.repo") ?: "../.."), "nemotron/results")
        val files = (nem.listFiles() ?: emptyArray()).map { File(it, "v21z/results.json") }.filter { it.exists() }
        assumeTrue("no nemotron/results here", files.isNotEmpty())
        for (f in files) {
            val s = JSONObject(f.readText()).arr("records").objects().onEach { it.put("seen_at", (it.getDouble("t") * 1000).toLong()) }
            check(Episodes.group(s), s)
        }
    }
}
