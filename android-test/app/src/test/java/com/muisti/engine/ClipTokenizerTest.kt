package com.muisti.engine

import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/** Token ids must equal the Python `tokenizers` output (src/test/resources/clip_tokens.json, 20 strings). */
class ClipTokenizerTest {
    @Test
    fun matchesPython() {
        val f = File("src/main/assets/clip_tokenizer.json")
        assumeTrue("tokenizer is downloaded by the build (fetchClipTokenizer)", f.exists())
        val tok = ClipTokenizer(f.readText())
        val cases = JSONArray(javaClass.getResource("/clip_tokens.json")!!.readText())
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val want = c.getJSONArray("ids").let { a -> (0 until a.length()).map { a.getInt(it) } }
            assertEquals(c.getString("text"), want, tok.encode(c.getString("text")))
        }
        val ids = tok.inputIds("a red sofa")
        assertEquals(77, ids.size); assertEquals(49406L, ids[0]); assertEquals(0L, ids[76])
    }
}
