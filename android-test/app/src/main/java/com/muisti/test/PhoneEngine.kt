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
    /** Release: no key in the APK, everything goes through the paired token proxy. Debug: the dev key from local.properties. */
    val tokens = com.muisti.engine.TokenClient(PrefsStore(ctx.getSharedPreferences("proxy", Context.MODE_PRIVATE)))
    val devKeys = BuildConfig.DEV_KEYS && BuildConfig.LLM_KEY.isNotEmpty()
    private val cfg = if (devKeys) LlmConfig(BuildConfig.LLM_BASE_URL, BuildConfig.LLM_MODEL, BuildConfig.LLM_KEY, BuildConfig.EMBED_KEY)
        else LlmConfig(BuildConfig.LLM_MODEL, { tokens.proxyUrl + "/proxy/llm/v1" }, tokens::token,
            { tokens.proxyUrl + "/proxy/retrieval" }, tokens::token)
    /** True when calls can be authorised (dev key, or paired with the proxy). */
    val canCall get() = devKeys || tokens.paired
    // fail-closed (PrivacyGate.CLOSED) until the app installs the real on-phone privacy check
    private val llm = Llm(cfg)

    /** The on-phone privacy check every outgoing image must pass (see Llm.gate). */
    fun setGate(gate: com.muisti.privacy.PrivacyGate) { llm.gate = gate }
    private val clip = ClipText(ctx)
    private val prompts = Prompts(ctx.assets.open("prompts.json").bufferedReader().use { it.readText() })
    private val extractor = Extractor(llm, prompts, AndroidImages)
    // v2: vectors from the Verda nemotron-3.5-embed deployment (the old NVIDIA-API cache is dropped, never mixed)
    private val embedder = cfg.embedder(File(ctx.filesDir, "embed_cache_v2.tsv"))
        .also { File(ctx.filesDir, "embed_cache.bin").delete() }
    private val asker = Asker(llm, prompts, AndroidImages, embedder)
    private val agent = com.muisti.engine.Agent(llm, prompts, asker).apply {
        // P2.6: cross-encoder only for ties; image channel = on-phone MobileCLIP text -> stored image vectors
        reranker = com.muisti.engine.Reranker({ cfg.embedKey }, { cfg.retrievalUrl })
        imageRank = { q -> clip.embed("a photo of $q")?.let { v -> store.vectors.search(v, 10).filter { it.second >= 0.20 }.map { "${it.first}.jpg" } } ?: emptyList() }
    }
    val store = MemoryStore(File(ctx.filesDir, "memory"))
    /** "note it": things the user explicitly asked to remember (searchable like memories). */
    val notes = com.muisti.engine.NoteStore(File(ctx.filesDir, "memory"))
    /** Episodes (stretches of the day), recomputed when the sightings change. */
    val episodes = com.muisti.engine.EpisodeStore(File(ctx.filesDir, "memory"))
    fun episodes(): List<com.muisti.engine.Episode> = episodes.update(store.sightings())
    private val summaryStore = com.muisti.engine.SummaryStore(File(ctx.filesDir, "memory"))
    private val summarizer = com.muisti.engine.EpisodeSummarizer(llm)
    /** Episode id -> verified AI summary (P2.4). */
    @Volatile var summaries: Map<String, String> = emptyMap(); private set

    /**
     * Background: summarises up to [max] CLOSED episodes (nothing joined for 10 min) that have no summary yet,
     * newest first, one Nemotron call each, from stored text only. Returns how many were written.
     */
    fun summarizePending(now: Long, max: Int = 2): Int {
        val eps = episodes()
        val todo = eps.filter { now - it.end > com.muisti.engine.Episodes.SETTLE_MS && summaryStore.get(it) == null }.takeLast(max).reversed()
        if (todo.isEmpty()) { summaries = summaryStore.valid(eps); return 0 }
        val byKey = store.sightings().associateBy { com.muisti.engine.Episodes.key(it) }
        var n = 0
        for (e in todo) {
            val items = Asker.docsFromSightings(e.members.mapNotNull { byKey[it] }).filter { it.type == "sighting" || it.type == "item" }
            val text = try { summarizer.summarize(e, items) } catch (x: com.muisti.engine.Unreachable) { break }
                catch (x: Exception) { android.util.Log.w("MuistiTiming", "summary failed: ${x.message}"); null }
            summaryStore.put(e, text ?: "")
            n++
        }
        summaries = summaryStore.valid(eps)
        android.util.Log.i("MuistiTiming", "episode summaries: wrote $n (${summarizer.calls} calls so far)")
        return n
    }
    private val recentWords = HashMap<String, Int>()   // like the server's _RECENT_WORDS, for ocr_repair

    /** Frames that could not go out while offline (redacted JPEG + OCR), retried after reconnect. */
    val pending = com.muisti.capture.PendingQueue(File(ctx.filesDir, "pending"))
    /** At most 3 frame requests at once, live uploads and queue retries together (questions are not limited). */
    private val ingestSlots = java.util.concurrent.Semaphore(3)

    /** A queued frame tried again: through the same ingest (so through the privacy gate again). */
    fun ingestPending(f: com.muisti.capture.PendingFrame): com.muisti.capture.Outcome = try {
        val fix = f.lat?.let { Fix(it, f.lon!!, 0f, f.seenAt, f.street) }
        if (ingest(f.jpeg, f.obs, f.seenAt, f.dhash, fix, f.vec)) com.muisti.capture.Outcome.SENT else com.muisti.capture.Outcome.DROPPED
    } catch (e: com.muisti.engine.Unreachable) { com.muisti.capture.Outcome.RETRY_LATER
    } catch (e: java.io.IOException) { com.muisti.capture.Outcome.RETRY_LATER }

    /** /ingest: lines from the phone's OCR boxes -> repair -> Nemotron -> verify -> store if useful. */
    fun ingest(jpeg: ByteArray, obs: List<Obs>, seenAtMs: Long, dhash: Long?, fix: Fix? = null, imageVec: FloatArray? = null): Boolean {
        ingestSlots.acquire()
        try { return ingestLimited(jpeg, obs, seenAtMs, dhash, fix, imageVec) } finally { ingestSlots.release() }
    }

    private fun ingestLimited(jpeg: ByteArray, obs: List<Obs>, seenAtMs: Long, dhash: Long?, fix: Fix?, imageVec: FloatArray?): Boolean {
        var lines = TextLines.visionToLines(obs)
        if (lines.isNotEmpty()) {
            synchronized(recentWords) {
                for ((w, c) in OcrRepair.buildVocab(lines)) recentWords.merge(w, c, Int::plus)
                lines = OcrRepair.repair(lines, HashMap(recentWords))
            }
        }
        val record = try { extractor.extract(jpeg, lines) } catch (e: com.muisti.engine.PrivacyBlocked) { return false }
        if (!record.bool("useful")) return false
        store.addFrame(seenAtMs, record, lines, jpeg, dhash, fix?.lat, fix?.lon, fix?.street, imageVec)
        warmSoon()
        return true
    }

    // --- speed: memories are turned into search docs + embedded in the background, not when a question comes ---

    private val docsLock = Any()
    private var docsFor: List<org.json.JSONObject>? = null
    private var notesFor = -1
    private var summariesFor: Map<String, String>? = null
    private var docsCache: List<com.muisti.engine.Doc> = emptyList()
    @Volatile private var lastWarm = 0L
    @Volatile private var warming = false

    /** Search docs for the current memory; rebuilt only when the store changed (vectors are kept on the Doc objects). */
    private fun docs(): List<com.muisti.engine.Doc> = synchronized(docsLock) {
        val s = store.sightings()
        if (s !== docsFor || notes.version != notesFor || summaries !== summariesFor) {
            val old = docsCache.filter { it.vec != null }.associateBy { it.text }
            docsCache = (Asker.docsFromSightings(s) + notes.docs() + com.muisti.engine.Episodes.docs(episodes.update(s), summaries))
                .onEach { d -> if (d.vec == null) d.vec = old[d.text]?.vec }
            docsFor = s; notesFor = notes.version; summariesFor = summaries
        }
        docsCache
    }

    /** At most every 8 s while recording: merge + embed new memories so the next question starts warm. */
    private fun warmSoon() {
        val now = System.currentTimeMillis()
        if (warming || now - lastWarm < 8_000) return
        warming = true; lastWarm = now
        Thread {
            runCatching { val d = docs(); asker.prewarm(d); asker.embedDocs(d) }
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
    fun ask(question0: String, liveFrame: ByteArray?, heard0: List<String> = emptyList(), fix: Fix? = null): Answer {
        // a bare "not eat" (no recognizer alternatives) is "note it" (D4); the original hearing is passed along
        val question = com.muisti.engine.SpeechFix.correct(question0, heard0)
        val heard = if (question != question0) heard0 + question0 else heard0
        val now = System.currentTimeMillis()
        val t0 = System.currentTimeMillis()
        val docs = docs()
        val tDocs = System.currentTimeMillis() - t0
        val t1 = System.currentTimeMillis()
        asker.semanticSetup(question, docs)      // embeds new memories + the question (cached)
        val tEmbed = System.currentTimeMillis() - t1
        val hist = synchronized(history) { history.toList() }
        val answer = try {
            agent.run(question, hist, docs, now, liveFrame, onForget = { m -> pending.forgetSince(now - m * 60_000L); notes.forgetSince(now - m * 60_000L); store.forget(now - m * 60_000L) },
                onCalendar = { ev -> addToCalendar(ev) }, heard = heard, extras = tools(liveFrame, fix))
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
                pending.forgetSince(now - minutes * 60_000L)
                notes.forgetSince(now - minutes * 60_000L)
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


    /** The memory a stored frame belongs to, as a search doc (for visual-search hits). */
    private fun docForFrame(frame: String): com.muisti.engine.Doc? {
        val sighting = store.sightings().firstOrNull { s -> s.optJSONArray("frames")?.let { a -> (0 until a.length()).any { a.optString(it) == frame } } == true }
            ?: return null
        val ev = sighting.optString("evidence_frame")
        return docs().firstOrNull { it.type == "sighting" && it.frame == ev }
    }

    // ---------------- Agent Center (P2.7) ----------------
    val notices = com.muisti.engine.NoticeStore(File(ctx.filesDir, "memory"))
    private val agentPrefs = ctx.getSharedPreferences("agent", Context.MODE_PRIVATE)
    var mutedNotices: Set<String>
        get() = agentPrefs.getStringSet("muted", emptySet())!!.toSet()
        set(v) { agentPrefs.edit().putStringSet("muted", v).apply() }

    /** Collects notices from every source and returns the ones to alert now (the rest wait in the inbox or are dropped). */
    fun checkNotices(now: Long, fix: Fix?, events: List<com.muisti.engine.CalEvent>): List<com.muisti.engine.Notice> {
        val d = docs()
        val cand = com.muisti.engine.NoticeSources.calendar(events, d, now) { t -> asker.ago(now, t) } +
            (fix?.let { com.muisti.engine.NoticeSources.arrival(it.lat, it.lon, notes.all(), now) } ?: emptyList()) +
            com.muisti.engine.NoticeSources.closingSoon(d, now)
        return notices.offer(cand, com.muisti.engine.InterventionPolicy(muted = mutedNotices), now)
    }

    // ---------------- Safety monitor (P2.8) ----------------
    val safetyRules = com.muisti.engine.SafetyRuleStore(File(ctx.filesDir, "memory"))
    private val safety = com.muisti.engine.SafetyMonitor({ safetyRules.all() }, imageCheck = { d, r ->
        // one look at the stored frame, through the privacy gate (a blocked or missing frame keeps the text verdict)
        asker.lookAgain(com.muisti.engine.Doc("object", d.seenAt, d.frame, store.frameDir.path, "safety", false, "${r.name} sign", "sign",
            text = r.name)).first
    })
    @Volatile private var safetyCheckedUpTo = System.currentTimeMillis() - 10 * 60_000L

    /** New memories since the last check -> safety notices that should alert now. Local text first. */
    @Synchronized
    fun checkSafety(now: Long): List<com.muisti.engine.Notice> {
        val fresh = docs().filter { it.type == "sighting" && it.seenAt > safetyCheckedUpTo }
        if (fresh.isEmpty()) return emptyList()
        safetyCheckedUpTo = fresh.maxOf { it.seenAt }
        val found = safety.evaluate(fresh, now)
        return if (found.isEmpty()) emptyList() else notices.offer(found, com.muisti.engine.InterventionPolicy(muted = mutedNotices), now)
    }

    /** Runs an action the user confirmed (see PendingAction). Returns what to tell the user. */
    fun execute(action: org.json.JSONObject): String = when (action.optString("type")) {
        "create_zone" -> {
            val z = com.muisti.privacy.Zones.newZone(action.getString("name"), action.getDouble("lat"), action.getDouble("lon"), action.getDouble("radius_m"))
            AppGraph.privacySettings.update { it.copy(zones = it.zones + z) }
            "Done. Nothing will be recorded within ${z.radiusM.toInt()} metres of here (${z.name})."
        }
        "add_safety_rule" -> {
            val r = com.muisti.engine.SafetyRule.fromJson(action.getJSONObject("rule"))
            safetyRules.add(r)
            "Done. I'll warn you when I read: ${r.phrases.joinToString(", ")}."
        }
        else -> "I can't do that."
    }

    /** Phone-only agent tools (the exported Python prompts are not changed). */
    private fun tools(liveFrame: ByteArray?, fix: Fix?): List<com.muisti.engine.ExtraTool> = listOf(
        com.muisti.engine.createZoneTool { fix?.let { Triple(it.lat, it.lon, it.street) } },
        com.muisti.engine.safetyRuleTool(),
        com.muisti.engine.visualSearchTool({ clip.embed(it) }, { store.vectors }, ::docForFrame),
        com.muisti.engine.noteTool { text, withView ->
            // the live frame given to ask() has already passed the privacy gate and been redacted
            notes.add(text, System.currentTimeMillis(), if (withView) liveFrame else null, fix?.lat, fix?.lon, fix?.street)
        },
    )

    fun frameFile(name: String) = if (name.startsWith("n")) File(notes.frameDir, name) else File(store.frameDir, name)

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
