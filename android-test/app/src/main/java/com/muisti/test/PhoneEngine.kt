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
    private val appCtx = ctx.applicationContext
    private val cfg = LlmConfig(BuildConfig.LLM_BASE_URL, BuildConfig.LLM_MODEL, BuildConfig.LLM_KEY, BuildConfig.EMBED_KEY)
    private val llm = Llm(cfg)
    private val prompts = Prompts(ctx.assets.open("prompts.json").bufferedReader().use { it.readText() })
    private val extractor = Extractor(llm, prompts, AndroidImages)
    private val embedder = Embedder(cfg.embedKey, File(ctx.filesDir, "embed_cache.tsv"))
    private val asker = Asker(llm, prompts, AndroidImages, embedder)
    private val agent = com.muisti.engine.Agent(llm, prompts, asker)
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
        warmSoon()
        return true
    }

    // --- speed: memories are turned into search docs + embedded in the background, not when a question comes ---

    private val docsLock = Any()
    private var docsFor: List<org.json.JSONObject>? = null
    private var docsCache: List<com.muisti.engine.Doc> = emptyList()
    @Volatile private var lastWarm = 0L
    @Volatile private var warming = false

    /** Search docs for the current memory; rebuilt only when the store changed (vectors are kept on the Doc objects). */
    private fun docs(): List<com.muisti.engine.Doc> = synchronized(docsLock) {
        val s = store.sightings()
        if (s !== docsFor) {
            val old = docsCache.filter { it.vec != null }.associateBy { it.text }
            docsCache = Asker.docsFromSightings(s).onEach { d -> if (d.vec == null) d.vec = old[d.text]?.vec }
            docsFor = s
        }
        docsCache
    }

    /** At most every 8 s while recording: merge + embed new memories so the next question starts warm. */
    private fun warmSoon() {
        val now = System.currentTimeMillis()
        if (warming || now - lastWarm < 8_000) return
        warming = true; lastWarm = now
        Thread {
            runCatching { asker.embedDocs(docs()) }
            warming = false
        }.start()
    }

    /** Called when the app opens / the voice session starts: the first question shouldn't pay for setup. */
    fun warm() { lastWarm = 0; warmSoon() }

    /**
     * /ask on the phone: the tool-calling Agent (Nemotron decides which tools to use, sees the
     * conversation so follow-ups work, and its final answer is verified by code). If the agent
     * fails (network, malformed tool call) the classic pipeline answers instead.
     */
    fun ask(question: String, liveFrame: ByteArray?): Answer {
        val now = System.currentTimeMillis()
        val t0 = System.currentTimeMillis()
        val docs = docs()
        val tDocs = System.currentTimeMillis() - t0
        val t1 = System.currentTimeMillis()
        asker.semanticSetup(question, docs)      // embeds new memories + the question (cached)
        val tEmbed = System.currentTimeMillis() - t1
        val hist = synchronized(history) { history.toList() }
        val answer = try {
            agent.run(question, hist, docs, now, liveFrame, onForget = { m -> store.forget(now - m * 60_000L) },
                onCalendar = { ev -> addToCalendar(ev) })
        } catch (e: Exception) {
            classic(question, docs, now, liveFrame)
        }
        remember(question, answer.answer)
        android.util.Log.i("MuistiTiming", "total ${System.currentTimeMillis() - t0}ms | docs ${tDocs}ms (${docs.size}) | " +
            "embed ${tEmbed}ms | agent: ${agent.timings.joinToString(", ")} | ${answer.label}")
        return answer
    }

    /** Writes the event straight into the phone's primary calendar (the user asked for it). */
    private fun addToCalendar(ev: com.muisti.engine.CalendarEvent): String {
        val cr = appCtx.contentResolver
        if (androidx.core.content.ContextCompat.checkSelfPermission(appCtx, android.Manifest.permission.WRITE_CALENDAR)
            != android.content.pm.PackageManager.PERMISSION_GRANTED) return "Not added: calendar permission is not granted. Tell the user to allow it."
        val proj = arrayOf(android.provider.CalendarContract.Calendars._ID, android.provider.CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
            android.provider.CalendarContract.Calendars.IS_PRIMARY, android.provider.CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL)
        var calId = -1L; var calName = ""; var bestPrimary = false
        cr.query(android.provider.CalendarContract.Calendars.CONTENT_URI, proj, "${android.provider.CalendarContract.Calendars.VISIBLE} = 1", null, null)?.use { c ->
            while (c.moveToNext()) {
                if (c.getInt(3) < android.provider.CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR) continue
                val primary = c.getInt(2) == 1
                if (calId < 0 || (primary && !bestPrimary)) { calId = c.getLong(0); calName = c.getString(1) ?: ""; bestPrimary = primary }
            }
        }
        if (calId < 0) return "Not added: no writable calendar on this phone."
        val v = android.content.ContentValues().apply {
            put(android.provider.CalendarContract.Events.CALENDAR_ID, calId)
            put(android.provider.CalendarContract.Events.TITLE, ev.title)
            put(android.provider.CalendarContract.Events.DTSTART, ev.startMs)
            put(android.provider.CalendarContract.Events.DTEND, ev.endMs)
            put(android.provider.CalendarContract.Events.EVENT_TIMEZONE, java.util.TimeZone.getDefault().id)
            put(android.provider.CalendarContract.Events.DESCRIPTION, ev.note)
            ev.location?.let { put(android.provider.CalendarContract.Events.EVENT_LOCATION, it) }
        }
        runCatching { cr.insert(android.provider.CalendarContract.Events.CONTENT_URI, v) }.getOrNull()
            ?: return "Not added: the calendar refused the event."
        val whenTxt = java.text.SimpleDateFormat("EEE d MMM, HH:mm", java.util.Locale.US).format(java.util.Date(ev.startMs))
        return "Added to the calendar '$calName': ${ev.title}, $whenTxt" + (ev.location?.let { ", at $it" } ?: "") + "."
    }

    private fun classic(question: String, docs: List<com.muisti.engine.Doc>, now: Long, liveFrame: ByteArray?): Answer {
        val r = asker.ask(question, docs, now, liveFrame)
        return when (r.label) {
            "FORGET" -> {
                val minutes = (r.parsed.num("minutes").takeIf { it > 0 } ?: 10.0).toInt()
                store.forget(now - minutes * 60_000L)
                Answer(question, "FORGOT", "Okay, I forgot everything from the last $minutes minutes.", emptyList(), emptyList(),
                    "forget $minutes min", r.calls, r.latencyS, r.parsed)
            }
            "ROUTE_CHAT" -> chat(question, now)
            else -> r
        }
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

    /** Translate sign text to English (detail sheet). Names stay as they are. */
    fun translate(text: String): String {
        val msgs = org.json.JSONArray()
            .put(org.json.JSONObject().put("role", "system").put("content",
                "Translate the text of a sign into natural English, line by line. Keep names, brands and numbers as they are. " +
                    "If a line is already English, repeat it. Output only the translation."))
            .put(org.json.JSONObject().put("role", "user").put("content", text))
        return llm.call(msgs, com.muisti.engine.RawJson.TEXT, 300, 0.0).trim()
    }
}
