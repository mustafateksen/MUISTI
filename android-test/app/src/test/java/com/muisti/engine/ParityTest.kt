package com.muisti.engine

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.util.TimeZone

/**
 * Parity with the Python pipeline, on the same memory and the same questions:
 *  1. Merge: Kotlin merge of the stored frames == Python's records (count, names, evidence frames)
 *  2. Ask:   eval/ask_tests.json through the Kotlin Asker, scored exactly like eval/run_ask_tests.py
 * Memory: nemotron/results/<video>/<MEM>/results.json (default v21z = Apple Vision + zoom).
 * Run: ./gradlew testDebugUnitTest --tests com.muisti.engine.ParityTest
 */
class ParityTest {
    private val repo = File(System.getProperty("muisti.repo") ?: "../..")
    private val nem = File(repo, "nemotron")
    private val mem = System.getProperty("muisti.mem") ?: "v21z"

    /** The Python test memories are not in git (results/ holds unblurred frames); without them these tests are skipped. */
    private fun memFiles(): List<File> {
        val all = (File(nem, "results").listFiles() ?: emptyArray()).map { File(it, "$mem/results.json") }.filter { it.exists() }.sortedBy { it.path }
        org.junit.Assume.assumeTrue("no test memories in nemotron/results/*/$mem (videos not processed on this machine)", all.isNotEmpty())
        return all
    }

    /** ask._video_start: WhatsApp name carries the send time; recording started ~90 s earlier. Naive clock as UTC. */
    private fun videoStart(path: String): Long {
        val m = Regex("""(\d{4}-\d{2}-\d{2})[ _]at[ _](\d{1,2})\.(\d{2})\.(\d{2})[ _](AM|PM)""").find(path)
            ?: return LocalDateTime.of(2026, 11, 13, 20, 0).toEpochSecond(ZoneOffset.UTC) * 1000
        val (d, h, mi, s, ap) = m.destructured
        val hour = h.toInt() % 12 + (if (ap == "PM") 12 else 0)
        val t = LocalDateTime.parse("${d}T00:00:00").withHour(hour).withMinute(mi.toInt()).withSecond(s.toInt()).minusSeconds(90)
        return t.toEpochSecond(ZoneOffset.UTC) * 1000
    }

    private fun parseNow(s: String) = LocalDateTime.parse(s).toEpochSecond(ZoneOffset.UTC) * 1000

    /** Android unit tests cannot see java.awt; the test frames (576x768) are under 1536 px, so no resize is needed. */
    object JvmImages : Images {
        override fun downscale(jpeg: ByteArray, longSide: Int): ByteArray = jpeg
    }

    @Test
    fun mergeMatchesPython() {
        for (f in memFiles()) {
            val d = JSONObject(f.readText())
            val rows = d.arr("rows").objects()
            val frames = rows.mapNotNull { r ->
                val rec = r.optJSONObject("record") ?: return@mapNotNull null
                Frame(r.getDouble("t"), r.getString("file"), rec, if (r.has("dhash") && !r.isNull("dhash")) r.getLong("dhash") else null)
            }
            val kt = Merge.mergeSightings(frames)
            val py = d.arr("records").objects()
            println("merge ${f.parentFile.parentFile.name.takeLast(12)}: python ${py.size} sightings, kotlin ${kt.size}")
            assertEquals("sighting count", py.size, kt.size)
            for ((a, b) in py.zip(kt)) {
                assertEquals("name", a.str("name"), b.str("name"))
                assertEquals("evidence frame", a.str("evidence_frame"), b.str("evidence_frame"))
                assertEquals("objects", a.arr("objects").length(), b.arr("objects").length())
                assertEquals("items", a.arr("items").length(), b.arr("items").length())
            }
        }
    }

    private var agent: Agent? = null

    private fun setup(): Triple<Asker, List<Doc>, Long> {
        TimeZone.setDefault(TimeZone.getTimeZone("UTC"))   // Python uses naive local clock values
        val cfg = LlmConfig(System.getProperty("muisti.llmBaseUrl")!!, System.getProperty("muisti.llmModel")!!,
            System.getProperty("muisti.llmKey")!!, System.getProperty("muisti.embedKey") ?: "")
        val prompts = Prompts(File(nem, "docs/prompts.json").readText())
        // PC evaluation of stored test frames: no phone privacy model here (the app never uses OPEN)
        val llm = Llm(cfg).apply { gate = com.muisti.privacy.PrivacyGate.OPEN }
        val asker = Asker(llm, prompts, JvmImages, Embedder(cfg.embedKey, File("build/embed_cache.tsv"))).apply { inlineEmbedLimit = Int.MAX_VALUE }
        agent = Agent(llm, prompts, asker).apply { preSearch = System.getProperty("muisti.presearch") != "0" }

        val sightings = memFiles().flatMap { f ->
            val start = videoStart(f.path)
            val src = f.parentFile.parentFile.name
            JSONObject(f.readText()).arr("records").objects().map {
                it.put("seen_at", start + (it.getDouble("t") * 1000).toLong()).put("source", src)
                    .put("frame_dir", File(f.parentFile, "frames").path)
            }
        }
        val docs = Asker.docsFromSightings(sightings)
        val spec = JSONObject(File(nem, "eval/ask_tests.json").readText())
        return Triple(asker, docs, parseNow(spec.getString("now")))
    }

    /** -Dmuisti.q="Where was the basketball hoop?": print parse + hits, to compare with Python's search(). */
    @Test
    fun debugQuestion() {
        val q = System.getProperty("muisti.q") ?: return
        val (asker, docs, now) = setup()
        val p = asker.parseQuestion(q)
        println("parsed $p")
        for ((sc, d) in asker.search(p, docs, now, qvec = asker.semanticSetup(q, docs)))
            println("KT %.3f %s %s %s".format(sc, d.type, d.frame, d.text.take(160)))
    }

    /** -Dmuisti.q="wear was the hoop" -Dmuisti.heard="where was the hoop|..." : misheard speech through the agent. */
    @Test
    fun misheardDebug() {
        val heard = System.getProperty("muisti.heard") ?: return
        val q = System.getProperty("muisti.q") ?: return
        val (_, docs, now) = setup()
        val r = agent!!.run(q, emptyList(), docs, now, heard = heard.split("|"))
        println("MISHEARD [${r.label}] ${r.answer}   (${r.why})")
    }

    /** -Dmuisti.agent=1: the same 31 questions through the tool-calling Agent (Nemotron native tools). */
    @Test
    fun askTestsLikePython() {
        if (System.getProperty("muisti.q") != null) return
        val (asker0, docs, now) = setup()
        val useAgent = System.getProperty("muisti.agent") == "1"
        val asker = object { fun ask(q: String, d: List<Doc>, n: Long) =
            if (useAgent) agent!!.run(q, emptyList(), d, n) else asker0.ask(q, d, n) }
        val spec = JSONObject(File(nem, "eval/ask_tests.json").readText())
        // build/parity_agent.{txt,json}: summary + per-question tool traces (RegressionReport)
        RegressionReport.run(spec.arr("questions").objects(), File(if (useAgent) "build/parity_agent" else "build/parity_ask")) { t ->
            asker.ask(t.getString("q"), docs, t.str("now")?.let { parseNow(it) } ?: now)
        }
    }

    /**
     * Replays a question on a memory pulled from the phone (-Dmuisti.phonemem=<dir with frames.jsonl>),
     * with the previous turn as history (-Dmuisti.hist="question|||answer"), and prints tools + cited evidence.
     */
    @Test
    fun phoneMemoryDebug() {
        val dir = System.getProperty("muisti.phonemem") ?: return
        val q = System.getProperty("muisti.q") ?: return
        setup()
        val store = MemoryStore(File(dir))
        val sightings = store.sightings()
        val docs = Asker.docsFromSightings(sightings)
        val now = sightings.maxOf { it.optLong("seen_at") } + 60_000
        val hist = System.getProperty("muisti.hist")?.split("|||")?.let { listOf(it[0] to it[1]) } ?: emptyList()
        repeat((System.getProperty("muisti.n") ?: "1").toInt()) {
            val r = agent!!.run(q, hist, docs, now)
            println("ANSWER [${r.label}] ${r.answer}")
            println("  why: ${r.why}")
            for (e in r.evidence.filter { it.id in r.used }) println("  USED ${e.id}: ${e.text.take(300)}")
        }
    }
}
