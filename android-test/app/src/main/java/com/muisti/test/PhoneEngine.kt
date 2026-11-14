package com.muisti.test

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.muisti.engine.Answer
import com.muisti.engine.Asker
import com.muisti.engine.Embedder
import com.muisti.engine.Extractor
import com.muisti.engine.Images
import com.muisti.engine.Llm
import com.muisti.engine.LlmConfig
import com.muisti.engine.MemoryStore
import com.muisti.engine.Obs
import com.muisti.engine.OcrRepair
import com.muisti.engine.Prompts
import com.muisti.engine.TextLines
import com.muisti.engine.bool
import java.io.ByteArrayOutputStream
import java.io.File

/** Android Bitmap implementation of the engine's image work. */
object AndroidImages : Images {
    override fun downscale(jpeg: ByteArray, longSide: Int): ByteArray {
        val bmp = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size) ?: return jpeg
        val l = maxOf(bmp.width, bmp.height)
        val scaled = if (l > longSide) {
            val s = longSide.toFloat() / l
            Bitmap.createScaledBitmap(bmp, (bmp.width * s).toInt(), (bmp.height * s).toInt(), true)
        } else bmp
        return ByteArrayOutputStream().also { scaled.compress(Bitmap.CompressFormat.JPEG, 85, it) }.toByteArray()
    }
}

/**
 * Everything the Python server did, on the phone: Nemotron is called directly (Verda), memory
 * lives in the app's files. Same code paths as the server's /ingest and /ask.
 */
class PhoneEngine(ctx: Context) {
    private val cfg = LlmConfig(BuildConfig.LLM_BASE_URL, BuildConfig.LLM_MODEL, BuildConfig.LLM_KEY, BuildConfig.EMBED_KEY)
    private val llm = Llm(cfg)
    private val prompts = Prompts(ctx.assets.open("prompts.json").bufferedReader().use { it.readText() })
    private val extractor = Extractor(llm, prompts, AndroidImages)
    private val embedder = Embedder(cfg.embedKey, File(ctx.filesDir, "embed_cache.tsv"))
    private val asker = Asker(llm, prompts, AndroidImages, embedder)
    val store = MemoryStore(File(ctx.filesDir, "memory"))
    private val recentWords = HashMap<String, Int>()   // like the server's _RECENT_WORDS, for ocr_repair

    /** /ingest: lines from the phone's OCR boxes -> repair -> Nemotron -> verify -> store if useful. */
    fun ingest(jpeg: ByteArray, obs: List<Obs>, seenAtMs: Long, dhash: Long?): Boolean {
        var lines = TextLines.visionToLines(obs)
        if (lines.isNotEmpty()) {
            synchronized(recentWords) {
                for ((w, c) in OcrRepair.buildVocab(lines)) recentWords.merge(w, c, Int::plus)
                lines = OcrRepair.repair(lines, HashMap(recentWords))
            }
        }
        val record = extractor.extract(jpeg, lines)
        if (!record.bool("useful")) return false
        store.addFrame(seenAtMs, record, lines, jpeg, dhash)
        return true
    }

    private val FORGET = Regex("""\bforget\b.*?\b(?:last|past)\s+(\d+|one|two|three|five|ten|fifteen|twenty|thirty)?\s*(minutes?|mins?|hours?)\b""", RegexOption.IGNORE_CASE)
    private val WORDS = mapOf("one" to 1, "two" to 2, "three" to 3, "five" to 5, "ten" to 10, "fifteen" to 15, "twenty" to 20, "thirty" to 30)

    /** /ask, plus the voice command "forget the last N minutes" and the live camera frame for "what is this?". */
    fun ask(question: String, liveFrame: ByteArray?): Answer {
        val now = System.currentTimeMillis()
        FORGET.find(question)?.let { m ->
            val n = m.groupValues[1].let { it.toIntOrNull() ?: WORDS[it.lowercase()] ?: 1 }
            val minutes = n * (if (m.groupValues[2].lowercase().startsWith("hour")) 60 else 1)
            store.forget(now - minutes * 60_000L)
            return Answer(question, "FORGOT", "Okay, I forgot everything from the last $minutes minutes.", emptyList(), emptyList(),
                "forget command", 0, 0.0, org.json.JSONObject())
        }
        val docs = Asker.docsFromSightings(store.sightings())
        val memory = if (docs.isEmpty() && liveFrame == null) null else asker.ask(question, docs, now, liveFrame)
        // Nothing in memory and the question is not about something seen ("what time is it?",
        // "how are you?") -> answer like a normal assistant. Memory questions stay strict: a
        // "did I see a piano?" with no match is still an honest "I didn't see it".
        val answer = if ((memory == null || (memory.label == "DONT_KNOW" && memory.why in CHAT_FALLBACK_WHY)) &&
            !MEMORY_Q.containsMatchIn(question)) chat(question, now)
        else memory ?: Answer(question, "DONT_KNOW", "I haven't seen anything yet.", emptyList(), emptyList(), "empty memory", 0, 0.0, org.json.JSONObject())
        remember(question, answer.answer)
        return answer
    }

    // --- small talk -------------------------------------------------------------------

    private val CHAT_FALLBACK_WHY = setOf("no relevant memory (gate)", "model abstained", "empty memory")
    /** Questions about the user's own past sightings: never answered from general knowledge. */
    private val MEMORY_Q = Regex("""\b((did|have|had) i (see|seen|saw|walk|pass|look|notice|read|visit)|i saw|i've seen|where (was|were|did|is|are|can i find)|which (floor|booth|shop|store|one)|when did i|what (did|was) (it|the|that) (say|show|written)|remember|earlier|before|last time|phone number|opening hours|how many .* (did i|were there))\b""", RegexOption.IGNORE_CASE)
    private val history = ArrayDeque<Pair<String, String>>()   // last turns, so a chat can refer back

    private fun remember(q: String, a: String) {
        synchronized(history) { history.addLast(q to a); while (history.size > 8) history.removeFirst() }
    }

    private fun chat(question: String, now: Long): Answer {
        val t0 = System.currentTimeMillis()
        val clock = java.text.SimpleDateFormat("EEEE d MMMM yyyy, HH:mm", java.util.Locale.US).format(java.util.Date(now))
        val system = """You are MUISTI, a warm, friendly voice assistant that lives in the user's smart glasses.
You also keep a visual memory of what the glasses saw, but this turn is ordinary conversation.
Current local date and time: $clock. Memories stored so far: ${store.sightings().size}.
Rules:
- Reply in 1-3 short spoken sentences, natural and a little personal, no markdown, no lists, no emoji.
- Answer the language the user speaks.
- You cannot browse the internet or see live data (weather, news, prices, scores): say so briefly and kindly if asked.
- Never invent things the user saw. If they ask about something they saw, tell them to ask you about it
  (e.g. "Ask me where you saw it and I'll check my memory").
- You can explain what you can do: remember what the glasses see (signs, places, objects, text), answer questions
  about it, summarise the last minutes, read what is in front of them right now, and forget the last minutes on request."""
        val msgs = org.json.JSONArray().put(org.json.JSONObject().put("role", "system").put("content", system))
        synchronized(history) {
            for ((q, a) in history) {
                msgs.put(org.json.JSONObject().put("role", "user").put("content", q))
                msgs.put(org.json.JSONObject().put("role", "assistant").put("content", a))
            }
        }
        msgs.put(org.json.JSONObject().put("role", "user").put("content", question))
        val text = llm.call(msgs, org.json.JSONObject().put("type", "text"), 250, 0.6).trim()
        return Answer(question, "CHAT", text, emptyList(), emptyList(), "small talk", 1,
            (System.currentTimeMillis() - t0) / 1000.0, org.json.JSONObject())
    }

    fun frameFile(name: String) = File(store.frameDir, name)
}
