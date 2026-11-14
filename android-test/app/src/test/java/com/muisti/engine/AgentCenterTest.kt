package com.muisti.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.util.TimeZone

class AgentCenterTest {
    @Before fun utc() = TimeZone.setDefault(TimeZone.getTimeZone("UTC"))
    private fun at(s: String) = LocalDateTime.parse(s).toEpochSecond(ZoneOffset.UTC) * 1000
    private fun n(id: String, type: String = Notice.CALENDAR, topic: String = id, t: Long, rel: Double = 1.0) = Notice(id, type, topic, id, "", t, rel)

    @Test
    fun maxOneAlertPer15Minutes() {
        val p = InterventionPolicy()
        val t0 = at("2026-11-14T12:00:00")
        val hist = ArrayList<Pair<Notice, Delivery>>()
        fun offer(x: Notice) = p.decide(x, x.createdAt, hist).also { hist.add(x to it) }
        assertEquals(Delivery.ALERT, offer(n("a", t = t0)))
        assertEquals(Delivery.INBOX, offer(n("b", t = t0 + 5 * 60_000)))
        assertEquals(Delivery.INBOX, offer(n("c", t = t0 + 14 * 60_000)))
        assertEquals(Delivery.ALERT, offer(n("d", t = t0 + 16 * 60_000)))
        // a 24-notice storm in one hour alerts at most 4 times
        val h2 = ArrayList<Pair<Notice, Delivery>>()
        val alerts = (0 until 24).count { i -> val x = n("s$i", t = t0 + i * 150_000L); p.decide(x, x.createdAt, h2).also { h2.add(x to it) } == Delivery.ALERT }
        assertTrue("alerts $alerts", alerts <= 4)
    }

    @Test
    fun quietHoursMutesRelevanceTopicsAndSafety() {
        val night = at("2026-11-14T23:30:00"); val day = at("2026-11-14T12:00:00")
        assertEquals(Delivery.INBOX, InterventionPolicy().decide(n("q", t = night), night, emptyList()))
        assertEquals(Delivery.ALERT, InterventionPolicy().decide(n("s", Notice.SAFETY, t = night), night, emptyList()))
        assertEquals(Delivery.DROP, InterventionPolicy(muted = setOf(Notice.CALENDAR)).decide(n("m", t = day), day, emptyList()))
        assertEquals(Delivery.DROP, InterventionPolicy().decide(n("low", t = day, rel = 0.2), day, emptyList()))
        val seen = listOf(n("x1", topic = "close:k-market", t = day - 3600_000) to Delivery.ALERT)
        assertEquals("same topic within 6 h", Delivery.DROP, InterventionPolicy().decide(n("x2", topic = "close:k-market", t = day), day, seen))
    }

    @Test
    fun calendarSourceFindsTheRelatedPoster() {
        val docs = Fixture.docs()
        val now = at("2026-11-15T13:40:00")
        val ev = CalEvent(7, "Junction Hackathon final demos", at("2026-11-15T14:00:00"), "Main Hall")
        val out = NoticeSources.calendar(listOf(ev, CalEvent(8, "Dentist", at("2026-11-15T18:00:00"), null)), docs, now) { "yesterday" }
        assertEquals(1, out.size)
        assertEquals("In 20 min: Junction Hackathon final demos", out[0].title)
        assertTrue(out[0].body, out[0].body.contains("Final demos"))
        assertEquals(listOf("8.jpg"), out[0].evidence.take(1))
        assertTrue("no related memory -> no notice", NoticeSources.calendar(listOf(CalEvent(9, "Yoga class", now + 600_000, null)), docs, now) { "" }.isEmpty())
    }

    @Test
    fun arrivalAtANotedPlace() {
        val notes = listOf(Note(1, at("2026-11-14T08:00:00"), "Buy oat milk here", null, 60.1675, 24.9420, "Annankatu"),
            Note(2, at("2026-11-14T17:50:00"), "Just noted", null, 60.1675, 24.9420, null))
        val now = at("2026-11-14T18:00:00")
        val near = NoticeSources.arrival(60.1680, 24.9425, notes, now)
        assertEquals(listOf("Buy oat milk here"), near.map { it.body })                  // note 2 is too fresh
        assertTrue(NoticeSources.arrival(60.1800, 24.9425, notes, now).isEmpty())          // 1.4 km away
    }

    @Test
    fun hoursAndClosingSoon() {
        assertEquals(20, Hours.closing("Ma-Pe 8-20, La 9-18", 2))     // Monday
        assertEquals(18, Hours.closing("Ma-Pe 8-20, La 9-18", 7))     // Saturday
        assertEquals(null, Hours.closing("Ma-Pe 8-20, La 9-18", 1))   // Sunday: not on the sign
        assertEquals(16, Hours.closing("Mon-Fri 8-16", 6))
        assertEquals(23, Hours.closing("Daily 7-23", 1))
        assertEquals(15, Hours.closing("Ma-Pe 7-18, La 9-15", 7))
        // Saturday 14 Nov 2026, 17:40: the pharmacy (La 9-18) closes in 20 min; K-Market (daily 7-23) does not
        val out = NoticeSources.closingSoon(Fixture.docs(), at("2026-11-14T17:40:00"))
        assertEquals(listOf("Kampin Apteekki closes in 20 min"), out.filter { it.type == Notice.CLOSING && it.title.contains("closes") }.map { it.title })
        // the fridge note says "by Friday": due on Friday 20 Nov, not on Saturday
        assertTrue(NoticeSources.closingSoon(Fixture.docs(), at("2026-11-14T09:00:00")).none { it.title == "Due today" })
        val fri = Fixture.docs().map { d -> if (d.type == "sighting") Doc(d.type, at("2026-11-20T08:06:00"), d.frame, d.frameDir, d.source, false, d.name, d.kind,
            d.subtype, d.phone, d.hours, d.text) else d }
        assertEquals(listOf("Due today"), NoticeSources.closingSoon(fri, at("2026-11-20T09:00:00")).filter { it.title == "Due today" }.map { it.title })
    }

    @Test
    fun storeOffersOnceAndKeepsTheInbox() {
        val s = NoticeStore(File("build/tmp/notices-${System.nanoTime()}").apply { mkdirs() })
        val t = at("2026-11-14T12:00:00")
        assertEquals(1, s.offer(listOf(n("a", t = t), n("b", t = t)), InterventionPolicy(), t).size)
        assertEquals("same ids again: nothing new", 0, s.offer(listOf(n("a", t = t)), InterventionPolicy(), t).size)
        assertEquals(listOf(Delivery.ALERT, Delivery.INBOX), s.all().map { it.second })
    }
}
