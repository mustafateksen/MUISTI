package com.muisti.engine

/**
 * Port of Python's difflib.SequenceMatcher(None, a, b).ratio() - the fuzzy matching in the
 * Python pipeline (fuzzy_in, name/merge similarity, token similarity) is all built on it, so the
 * Android engine must give the same numbers. Includes the autojunk "popular element" rule for
 * b of length >= 200, exactly as CPython does it.
 */
object Difflib {

    fun ratio(a: String, b: String): Double {
        val la = a.length
        val lb = b.length
        if (la + lb == 0) return 1.0
        return 2.0 * matches(a, b) / (la + lb)
    }

    private fun matches(a: String, b: String): Int {
        val n = b.length
        // b2j: char -> ascending indices in b
        val b2j = HashMap<Char, MutableList<Int>>()
        for (i in 0 until n) b2j.getOrPut(b[i]) { ArrayList() }.add(i)
        if (n >= 200) {   // autojunk: drop elements that make up more than 1% of b
            val ntest = n / 100 + 1
            b2j.entries.removeIf { it.value.size > ntest }
        }
        var total = 0
        val queue = ArrayDeque<IntArray>()
        queue.addLast(intArrayOf(0, a.length, 0, n))
        while (queue.isNotEmpty()) {
            val (alo, ahi, blo, bhi) = queue.removeLast()
            val m = longest(a, b, b2j, alo, ahi, blo, bhi)
            val i = m[0]; val j = m[1]; val k = m[2]
            if (k > 0) {
                total += k
                if (alo < i && blo < j) queue.addLast(intArrayOf(alo, i, blo, j))
                if (i + k < ahi && j + k < bhi) queue.addLast(intArrayOf(i + k, ahi, j + k, bhi))
            }
        }
        return total
    }

    private fun longest(a: String, b: String, b2j: Map<Char, List<Int>>, alo: Int, ahi: Int, blo: Int, bhi: Int): IntArray {
        var besti = alo
        var bestj = blo
        var bestsize = 0
        var j2len = HashMap<Int, Int>()
        for (i in alo until ahi) {
            val newj2len = HashMap<Int, Int>()
            val idxs = b2j[a[i]]
            if (idxs != null) {
                for (j in idxs) {
                    if (j < blo) continue
                    if (j >= bhi) break
                    val k = (j2len[j - 1] ?: 0) + 1
                    newj2len[j] = k
                    if (k > bestsize) { besti = i - k + 1; bestj = j - k + 1; bestsize = k }
                }
            }
            j2len = newj2len
        }
        // No junk function -> bjunk is empty; popular elements are not junk, so extend over equal chars.
        while (besti > alo && bestj > blo && a[besti - 1] == b[bestj - 1]) { besti--; bestj--; bestsize++ }
        while (besti + bestsize < ahi && bestj + bestsize < bhi && a[besti + bestsize] == b[bestj + bestsize]) bestsize++
        return intArrayOf(besti, bestj, bestsize)
    }
}
