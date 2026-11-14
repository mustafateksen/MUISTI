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
        val llm = Llm(cfg)
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

/** The fixture memory as sightings / docs (frames do not exist on disk: look-again trusts the memory). */
object Fixture {
    fun sightings(): List<JSONObject> =
        JSONObject(Fixture::class.java.getResource("/fixture_memory.json")!!.readText()).arr("sightings").objects()
            .onEach { it.put("frame_dir", "build/no_frames") }
    fun docs(): List<Doc> = Asker.docsFromSightings(sightings())
    fun now(): Long = LocalDateTime.parse("2026-11-14T18:30:00").toEpochSecond(ZoneOffset.UTC) * 1000
}
