package com.muisti.engine

import org.json.JSONObject
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.util.TimeZone

/**
 * Agent regression on the committed fixture memory (src/test/resources/fixture_memory.json): a synthetic day with
 * 10 answerable questions and 10 traps. Runs against the live model only with -Dmuisti.fixture=1.
 * Output: build/fixture_agent.txt + build/fixture_agent.json (per-question tool traces).
 */
class FixtureRegressionTest {
    @Test
    fun fixtureAgent() {
        assumeTrue("needs the live model: -Dmuisti.fixture=1", System.getProperty("muisti.fixture") == "1")
        val key = System.getProperty("muisti.llmKey"); assumeTrue("no key in local.properties", !key.isNullOrEmpty())
        TimeZone.setDefault(TimeZone.getTimeZone("UTC"))
        val repo = File(System.getProperty("muisti.repo") ?: "../..")
        val cfg = LlmConfig(System.getProperty("muisti.llmBaseUrl")!!, System.getProperty("muisti.llmModel")!!, key!!,
            System.getProperty("muisti.embedKey") ?: "")
        val prompts = Prompts(File(repo, "nemotron/docs/prompts.json").readText())
        // PC evaluation of stored test frames: no phone privacy model here (the app never uses OPEN)
        val llm = Llm(cfg).apply { gate = com.muisti.privacy.PrivacyGate.OPEN }
        val asker = Asker(llm, prompts, ParityTest.JvmImages, Embedder(cfg.embedKey, File("build/fixture_embed.tsv")))
        val agent = Agent(llm, prompts, asker)
        val docs = Fixture.docs()
        val spec = JSONObject(javaClass.getResource("/fixture_questions.json")!!.readText())
        val now = LocalDateTime.parse(spec.getString("now")).toEpochSecond(ZoneOffset.UTC) * 1000
        RegressionReport.run(spec.arr("questions").objects(), File("build/fixture_agent")) { t ->
            agent.run(t.getString("q"), emptyList(), docs, now)
        }
    }
}

/** Live: "note it" commands, including misheard ones, end as NOTED through the real model (-Dmuisti.fixture=1). */
class NoteCommandsLiveTest {
    @Test
    fun noteCommands() {
        assumeTrue(System.getProperty("muisti.fixture") == "1")
        val key = System.getProperty("muisti.llmKey"); assumeTrue(!key.isNullOrEmpty())
        val cfg = LlmConfig(System.getProperty("muisti.llmBaseUrl")!!, System.getProperty("muisti.llmModel")!!, key!!, key)
        val llm = Llm(cfg).apply { gate = com.muisti.privacy.PrivacyGate.OPEN }
        val asker = Asker(llm, prompts(), ParityTest.JvmImages, null)
        val agent = Agent(llm, prompts(), asker)
        val cases = listOf("note that my bike is locked at the back door" to emptyList(),
            "not eat" to listOf("note it", "not it"),                    // misheard, with alternatives: the model decides
            SpeechFix.correct("not eat", emptyList()) to listOf("not eat"), // bare mishearing fixed in code
            "remember that the dentist appointment is on Tuesday" to emptyList())
        var ok = 0
        for ((q, heard) in cases) {
            val saved = ArrayList<String>()
            val r = agent.run(q, listOf("What did the bakery sign say?" to "Leipomo Kanelia, open 7 to 18."), Fixture.docs(), Fixture.now(),
                heard = heard, extras = listOf(noteTool { t, _ -> saved.add(t); Note(1, 0, t, null, null, null, null) }))
            println("NOTE [${r.label}] '$q' -> ${saved.firstOrNull()}  (${r.why})")
            if (r.label == "NOTED" && saved.isNotEmpty()) ok++
        }
        println("note commands: $ok/${cases.size}")
        org.junit.Assert.assertEquals(cases.size, ok)
    }
}

/** The fixture memory as sightings / docs (frames do not exist on disk: look-again trusts the memory). */
object Fixture {
    fun sightings(): List<JSONObject> =
        JSONObject(Fixture::class.java.getResource("/fixture_memory.json")!!.readText()).arr("sightings").objects()
            .onEach { it.put("frame_dir", "build/no_frames") }
    fun docs(): List<Doc> = Asker.docsFromSightings(sightings())
    fun now(): Long = LocalDateTime.parse("2026-11-14T18:30:00").toEpochSecond(ZoneOffset.UTC) * 1000
}
