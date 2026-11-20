package com.muisti.engine

import org.json.JSONObject
import java.text.Normalizer

/**
 * The CLIP BPE tokenizer of MobileCLIP-S0 (Xenova/mobileclip_s0 tokenizer.json), in plain Kotlin so the phone can
 * embed a search text without the network. Same steps as the HF tokenizer: NFC, whitespace collapse, lower case,
 * CLIP's split regex, GPT-2 byte-to-unicode mapping, BPE with the "</w>" end-of-word suffix, start/end tokens.
 * Checked token by token against the Python `tokenizers` library (ClipTokenizerTest).
 */
class ClipTokenizer(tokenizerJson: String) {
    private val vocab: Map<String, Int>
    private val ranks: Map<String, Int>
    private val cache = HashMap<String, List<String>>()

    init {
        val model = JSONObject(tokenizerJson).getJSONObject("model")
        val v = model.getJSONObject("vocab")
        vocab = HashMap<String, Int>(v.length() * 2).apply { for (k in v.keys()) put(k, v.getInt(k)) }
        val m = model.getJSONArray("merges")
        ranks = HashMap<String, Int>(m.length() * 2).apply {
            for (i in 0 until m.length()) {
                val e = m.get(i)
                val pair = if (e is String) e else (e as org.json.JSONArray).let { "${it.getString(0)} ${it.getString(1)}" }
                put(pair, i)
            }
        }
    }

    companion object {
        const val BOS = 49406; const val EOS = 49407; const val CONTEXT = 77
        private val SPLIT = Regex("""'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+""")
        /** GPT-2's reversible byte -> printable unicode map. */
        private val BYTE_TO_UNICODE: Array<String> = run {
            val bs = ((33..126) + (161..172) + (174..255)).toMutableList()
            val cs = bs.toMutableList(); var n = 0
            for (b in 0..255) if (b !in bs) { bs.add(b); cs.add(256 + n); n++ }
            val out = Array(256) { "" }
            for ((b, c) in bs.zip(cs)) out[b] = String(Character.toChars(c))
            out
        }
    }

    fun normalize(s: String): String = Normalizer.normalize(s, Normalizer.Form.NFC).replace(Regex("""\s+"""), " ").lowercase()

    private fun bpe(word: String): List<String> = cache.getOrPut(word) {
        val sym = ArrayList<String>()
        var i = 0
        while (i < word.length) { val cp = word.codePointAt(i); sym.add(String(Character.toChars(cp))); i += Character.charCount(cp) }
        if (sym.isEmpty()) return@getOrPut emptyList()
        sym[sym.size - 1] = sym.last() + "</w>"
        while (sym.size > 1) {
            var best = -1; var bestRank = Int.MAX_VALUE
            for (j in 0 until sym.size - 1) { val r = ranks["${sym[j]} ${sym[j + 1]}"] ?: continue; if (r < bestRank) { bestRank = r; best = j } }
            if (best < 0) break
            val a = sym[best]; val b = sym[best + 1]
            // merge every occurrence of this pair, left to right (as BPE does)
            val merged = ArrayList<String>(sym.size)
            var k = 0
            while (k < sym.size) {
                if (k < sym.size - 1 && sym[k] == a && sym[k + 1] == b) { merged.add(a + b); k += 2 } else { merged.add(sym[k]); k++ }
            }
            sym.clear(); sym.addAll(merged)
        }
        sym
    }

    /** Token ids with start and end tokens (no padding). */
    fun encode(text: String): List<Int> {
        val ids = arrayListOf(BOS)
        for (m in SPLIT.findAll(normalize(text))) {
            val mapped = m.value.toByteArray(Charsets.UTF_8).joinToString("") { BYTE_TO_UNICODE[it.toInt() and 255] }
            for (t in bpe(mapped)) ids.add(vocab[t] ?: EOS)
        }
        ids.add(EOS)
        return ids
    }

    /** Model input: [CONTEXT] ids, zero padded (as tools/make_privacy_prompts.py feeds the text model). */
    fun inputIds(text: String): LongArray {
        val ids = encode(text).take(CONTEXT)
        return LongArray(CONTEXT) { if (it < ids.size) ids[it].toLong() else 0L }
    }
}
