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
import com.muisti.engine.num
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
    fun ingest(jpeg: ByteArray, obs: List<Obs>, seenAtMs: Long, dhash: Long?, fix: Fix? = null): Boolean {
        var lines = TextLines.visionToLines(obs)
        if (lines.isNotEmpty()) {
            synchronized(recentWords) {
                for ((w, c) in OcrRepair.buildVocab(lines)) recentWords.merge(w, c, Int::plus)
                lines = OcrRepair.repair(lines, HashMap(recentWords))
            }
        }
        val record = extractor.extract(jpeg, lines)
        if (!record.bool("useful")) return false
        store.addFrame(seenAtMs, record, lines, jpeg, dhash, fix?.lat, fix?.lon, fix?.street)
        return true
    }

    /** /ask on the phone. Nemotron reads the request (memory / live / summary / forget / chat) in its parse call. */
    fun ask(question: String, liveFrame: ByteArray?): Answer {
        val now = System.currentTimeMillis()
        val docs = Asker.docsFromSightings(store.sightings())
        val r = asker.ask(question, docs, now, liveFrame)
        val answer = when (r.label) {
            "FORGET" -> {
                val minutes = (r.parsed.num("minutes").takeIf { it > 0 } ?: 10.0).toInt()
                store.forget(now - minutes * 60_000L)
                Answer(question, "FORGOT", "Okay, I forgot everything from the last $minutes minutes.", emptyList(), emptyList(),
                    "forget $minutes min", r.calls, r.latencyS, r.parsed)
            }
            "ROUTE_CHAT" -> chat(question, now)
            else -> if (docs.isEmpty() && r.label == "DONT_KNOW") Answer(question, "DONT_KNOW", "I haven't seen anything yet.",
                emptyList(), emptyList(), "empty memory", r.calls, r.latencyS, r.parsed) else r
        }
        remember(question, answer.answer)
        return answer
    }

    // --- small talk -------------------------------------------------------------------

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
        val text = llm.call(msgs, com.muisti.engine.RawJson.TEXT, 250, 0.6).trim()
        return Answer(question, "CHAT", text, emptyList(), emptyList(), "small talk", 1,
            (System.currentTimeMillis() - t0) / 1000.0, org.json.JSONObject())
    }

    fun frameFile(name: String) = File(store.frameDir, name)
}
