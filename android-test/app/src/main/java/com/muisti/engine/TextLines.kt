package com.muisti.engine

import kotlin.math.abs

/** One text box from the phone's OCR (ML Kit / Apple Vision): normalised 0..1, origin top-left. */
data class Obs(val text: String, val conf: Double, val x: Double, val y: Double, val w: Double, val h: Double)

/** Port of ocr_adapter.py: OCR boxes -> rows of text in reading order (side-by-side boxes on one row). */
object TextLines {

    fun visionToLines(observations: List<Obs>, minConf: Double = 0.3, rowOverlap: Double = 0.5): List<String> {
        val obs = observations.filter { it.text.isNotBlank() && it.conf >= minConf }
            .sortedWith(compareBy({ it.y }, { it.x }))
        val rows = ArrayList<MutableList<Obs>>()
        for (o in obs) {
            var placed = false
            for (row in rows) {
                val ry = row.minOf { it.y }
                val rb = row.maxOf { it.y + it.h }
                val overlap = minOf(o.y + o.h, rb) - maxOf(o.y, ry)
                if (overlap >= rowOverlap * minOf(o.h, rb - ry)) { row.add(o); placed = true; break }
            }
            if (!placed) rows.add(mutableListOf(o))
        }
        val sorted = rows.map { r -> r.sortedBy { it.x }.toMutableList() }.toMutableList()
        return joinWrappedValues(sorted).map { r -> r.joinToString("  ") { it.text.trim() } }
    }

    /**
     * A value wrapped onto two lines next to ONE label ("5TH FLOOR" centred between
     * "ARDUINO HARDWARE LAB" / "& HACKING SPACE") becomes a lone row + a label row: glue it back.
     */
    private fun joinWrappedValues(rows: MutableList<MutableList<Obs>>, xTol: Double = 0.025): List<List<Obs>> {
        fun top(o: Obs) = o.y
        fun bot(o: Obs) = o.y + o.h
        val out = rows.map { it.toMutableList() }.toMutableList()
        var i = 0
        while (i < out.size) {
            val row = out[i]
            if (row.size != 1) { i++; continue }
            val lone = row[0]
            val h = lone.h
            var joined = false
            for ((j, below) in listOf(i + 1 to true, i - 1 to false)) {
                if (j !in out.indices || out[j].size < 2) continue
                val nb = out[j]
                val label = nb[0]
                for (k in 1 until nb.size) {
                    val v = nb[k]
                    if (abs(v.x - lone.x) > xTol) continue
                    val gap = if (below) top(v) - bot(lone) else top(lone) - bot(v)
                    val seam = if (below) (bot(lone) + top(v)) / 2 else (bot(v) + top(lone)) / 2
                    val centred = abs((top(label) + bot(label)) / 2 - seam) < 0.18 * h
                    if (gap > -0.5 * h && gap < 0.6 * h && centred) {
                        val text = if (below) lone.text.trim() + " " + v.text.trim() else v.text.trim() + " " + lone.text.trim()
                        nb[k] = v.copy(text = text)
                        out.removeAt(i)
                        joined = true
                        break
                    }
                }
                if (joined) break
            }
            if (!joined) i++
        }
        return out
    }
}

/** Port of ocr_repair.py: ordinals ("STH FLOOR" -> "5TH FLOOR") and glued words, using only words read elsewhere. */
object OcrRepair {
    private val DIGIT = mapOf('S' to '5', 'O' to '0', 'I' to '1', 'l' to '1', 'B' to '8', 'Z' to '2', 'G' to '6')
    private val SUFFIX_DIGIT = mapOf("ST" to "1", "ND" to "2", "RD" to "3")
    private val ORD_GLUED = Regex("""\b([0-9SOIlBZG])(TH|ST|ND|RD)\s*(FLOOR|FL)\b""", RegexOption.IGNORE_CASE)
    private val TOKEN = Regex("[A-Za-z]{3,}")
    private val NON_LETTERS = Regex("[^A-Za-z]+")

    fun buildVocab(lines: Iterable<String>): MutableMap<String, Int> {
        val vocab = HashMap<String, Int>()
        for (line in lines) for (w in line.split(NON_LETTERS)) if (w.length >= 3) vocab.merge(w.uppercase(), 1, Int::plus)
        return vocab
    }

    private fun split(token: String, vocab: Map<String, Int>): List<String>? {
        val up = token.uppercase()
        val n = token.length
        val best = arrayOfNulls<List<String>>(n + 1)
        best[0] = emptyList()
        for (i in 0 until n) {
            val bi = best[i] ?: continue
            for (j in i + 3..n) {
                val bj = best[j]
                if ((vocab[up.substring(i, j)] ?: 0) >= 2 && (bj == null || bi.size + 1 < bj.size)) best[j] = bi + token.substring(i, j)
            }
        }
        val parts = best[n]
        return if (parts != null && parts.size >= 2) parts else null
    }

    fun repairLine(line0: String, vocab: Map<String, Int>): String {
        val line = ORD_GLUED.replace(line0) { m ->
            var ch = m.groupValues[1]
            val suf = m.groupValues[2].uppercase()
            if (!ch[0].isDigit()) ch = SUFFIX_DIGIT[suf] ?: (DIGIT[ch[0]]?.toString() ?: ch)
            ch + suf + " " + m.groupValues[3]
        }
        return TOKEN.replace(line) { m ->
            val tok = m.value
            if (tok.length < 7) return@replace tok
            val up = tok.uppercase()
            // a cut-off read of a longer known word ("Cloudinar" of CLOUDINARY) is not a glued pair
            if (vocab.any { (w, c) -> c >= 2 && w != up && w.contains(up) }) return@replace tok
            val parts = split(tok, vocab)
            // a real word read often on its own (HARDWARE) is never split; a glued token is rarer than its parts
            if (parts == null || (vocab[up] ?: 0) >= parts.minOf { vocab[it.uppercase()] ?: 0 }) tok
            else parts.joinToString(" ")
        }
    }

    fun repair(lines: List<String>, vocab: Map<String, Int>) = lines.map { repairLine(it, vocab) }
}
