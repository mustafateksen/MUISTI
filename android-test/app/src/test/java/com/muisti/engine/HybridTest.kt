package com.muisti.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HybridTest {
    private fun d(n: String) = Doc("sighting", 0, "$n.jpg", null, "t", false, n, "k", text = n)

    @Test
    fun rrfRewardsAgreementBetweenLists() {
        val a = d("a"); val b = d("b"); val c = d("c"); val x = d("x")
        // keyword: a, b, c ; text vectors: c, b ; image: b
        val fused = Hybrid.rrf(listOf(listOf(a, b, c) to 1.0, listOf(c, b) to 1.0, listOf(b) to 1.0, listOf(x) to 0.0))
        assertEquals(listOf("b", "c", "a", "x"), fused.map { it.first.name })
        assertEquals(3 / 62.0 + 0.0, fused[0].second, 1e-3)
    }

    @Test
    fun closeMeansWithinOneTopRankStep() {
        val a = d("a"); val b = d("b")
        assertTrue(Hybrid.close(listOf(a to 0.0328, b to 0.0326)))
        assertFalse(Hybrid.close(listOf(a to 0.0490, b to 0.0328)))
        assertFalse(Hybrid.close(listOf(a to 0.0490)))
    }

    @Test
    fun rerankerFailsSoftWithoutKey() = assertEquals(null, Reranker({ "" }).scores("q", listOf("d")))
}
