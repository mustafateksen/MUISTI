package com.muisti.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CaptureSchedulerTest {
    private val still = CaptureSignals(accRms = 0.1, gpsSpeed = 0.2f, gpsAccuracy = 8f)
    private val walking = CaptureSignals(accRms = 1.4, gpsSpeed = 1.3f, gpsAccuracy = 8f)

    @Test
    fun policyTable() {
        assertEquals(Motion.FAST, CaptureScheduler.classify(CaptureSignals(accRms = 0.3, gpsSpeed = 9f, gpsAccuracy = 5f)))
        assertEquals(Motion.WALKING, CaptureScheduler.classify(walking))
        assertEquals(Motion.WALKING, CaptureScheduler.classify(CaptureSignals(accRms = 0.2, gpsSpeed = 1.5f, gpsAccuracy = 10f)))
        assertEquals("rough GPS is not trusted", Motion.STILL, CaptureScheduler.classify(CaptureSignals(accRms = 0.2, gpsSpeed = 6f, gpsAccuracy = 60f)))
        assertEquals(Motion.STILL, CaptureScheduler.classify(still))
        assertEquals(Motion.UNKNOWN, CaptureScheduler.classify(CaptureSignals()))

        assertEquals(1000L, CaptureScheduler().decide(walking).intervalMs)
        assertEquals(1500L, CaptureScheduler().decide(CaptureSignals()).intervalMs)
        val s = CaptureScheduler()
        val first = (1..12).map { s.decide(still).intervalMs }
        assertTrue(first.all { it == 3000L })
        assertEquals("long still: refresh slows down", 7500L, s.decide(still).intervalMs)
        s.onKept(bitsChanged = 30)                                    // head turn
        assertEquals(1000L, s.decide(still).intervalMs)
        assertEquals(3000L, s.decide(still).intervalMs)
    }

    @Test
    fun batteryAndHeat() {
        assertEquals(1500L, CaptureScheduler().decide(walking.copy(powerSave = true)).intervalMs)
        assertEquals(3000L, CaptureScheduler().decide(walking.copy(glassesBattery = 8)).intervalMs)
        assertEquals(2000L, CaptureScheduler().decide(walking.copy(glassesBattery = 15)).intervalMs)
        assertEquals(2000L, CaptureScheduler().decide(walking.copy(phoneThermal = 2)).intervalMs)
        assertEquals(6000L, CaptureScheduler().decide(walking.copy(phoneBattery = 10, glassesThermal = "SEVERE", glassesBattery = 15)).intervalMs)
        val hot = CaptureScheduler().decide(walking.copy(phoneThermal = 3))
        assertTrue(hot.paused); assertEquals("phone is too hot", hot.reason)
        assertTrue(CaptureScheduler().decide(walking.copy(glassesThermal = "CRITICAL")).paused)
    }

    /** 60 s standing still vs 60 s walking: kept frames (= Nemotron requests at most) drop by >= 50 %. */
    @Test
    fun standingStillHalvesTheRequests() {
        fun windows(sig: CaptureSignals): Int {
            val s = CaptureScheduler(); var t = 0L; var n = 0
            while (true) { t += s.decide(sig).intervalMs; if (t > 60_000) break; n++ }
            return n
        }
        val w = windows(walking); val st = windows(still)
        println("60 s: walking $w windows, still $st windows")
        assertTrue("still $st vs walking $w", st <= w / 2)
    }
}
