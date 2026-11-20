package com.muisti.capture

import com.muisti.engine.Obs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

class PendingQueueTest {
    private fun dir() = File("build/tmp/pq-${System.nanoTime()}")
    private fun frame(t: Long) = PendingFrame("f$t", byteArrayOf(1, 2, 3), listOf(Obs("APTEEKKI", 0.9, 0.1, 0.2, 0.3, 0.05)), t, 42L, 60.17, 24.94, "Simonkatu")

    @Test
    fun survivesRestartInOrderWithCap() {
        val d = dir()
        val q = PendingQueue(d, max = 5)
        for (t in 1L..8L) q.add(frame(1000 + t))
        val again = PendingQueue(d, max = 5)                  // app killed and restarted
        assertEquals(5, again.size())
        val f = again.oldest()!!
        assertEquals("oldest kept is #4 (1..3 dropped when full)", 1004L, f.seenAt)
        assertEquals("APTEEKKI", f.obs[0].text); assertEquals(42L, f.dhash); assertEquals("Simonkatu", f.street)
        again.forgetSince(1007)
        assertEquals(3, again.size())
    }

    /** Airplane mode for a minute, then back: queued frames go out one by one, paced, never all at once. */
    @Test
    fun drainsAfterReconnectWithoutAStorm() {
        val q = PendingQueue(dir())
        for (t in 1L..20L) q.add(frame(t))
        var online = false
        val inFlight = AtomicInteger(); var maxInFlight = 0; val sent = ArrayList<Long>(); val pauses = ArrayList<Long>()
        val drainer = Drainer(q, pauseMs = 1500) { pauses.add(it) }
        val send = { f: PendingFrame ->
            maxInFlight = maxOf(maxInFlight, inFlight.incrementAndGet()); sent.add(f.seenAt); inFlight.decrementAndGet(); Outcome.SENT
        }
        assertEquals("offline: nothing is tried", 0, drainer.drain({ online }, send))
        online = true
        assertEquals(20, drainer.drain({ online }, send))
        assertEquals((1L..20L).toList(), sent)                 // oldest first
        assertEquals(1, maxInFlight)
        assertTrue(pauses.size == 19 && pauses.all { it == 1500L })
        assertEquals(0, q.size())
    }

    @Test
    fun serverStillDownStopsTheRoundAndKeepsTheFrame() {
        val q = PendingQueue(dir())
        q.add(frame(1)); q.add(frame(2))
        var calls = 0
        val n = Drainer(q) {}.drain({ true }, { calls++; if (calls == 1) Outcome.SENT else Outcome.RETRY_LATER })
        assertEquals(1, n); assertEquals(1, q.size())
        // privacy-dropped frames (the gate said private on retry) are removed, not retried
        assertEquals(1, Drainer(q) {}.drain({ true }, { Outcome.DROPPED })); assertEquals(0, q.size())
    }
}
