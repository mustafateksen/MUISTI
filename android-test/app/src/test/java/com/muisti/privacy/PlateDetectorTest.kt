package com.muisti.privacy

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlateDetectorTest {
    private val plates = listOf("ABC-123", "XYZ-12", "KLM 456", "ABC 12A", "B-MW 1234", "M AB 123", "AB-123-CD", "AB 123 CD",
        "AB12 CDE", "123 ABC", "FI ABC-123", "CCC-999", "Ab-1234")
    private val signs = listOf("K-Market", "Kampin Apteekki", "SALE -50%", "1,89 €", "Ma-Pe 8-20", "puh. 09 1234 567", "OPEN 24H",
        "Room B204", "Bus 14", "24/7", "A4", "Level 3", "WC 2", "E18", "EXIT", "MON-FRI 8", "Gate 12", "Oat milk 1.89", "LOT 2026",
        "Leipomo Kanelia", "Hätäuloskäytävä", "Coca-Cola", "100 g", "Floor 5")

    @Test
    fun platesAreRecognised() {
        for (p in plates) assertTrue("plate: $p", PlateDetector.looksLikePlate(p))
    }

    @Test
    fun signsPricesAndHoursAreNot() {
        for (s in signs) assertFalse("not a plate: $s", PlateDetector.looksLikePlate(s))
    }

    @Test
    fun boxShapeAndContextMatter() {
        val w = 1280; val h = 960
        val plate = TextBox("ABC-123", 0.40, 0.70, 0.12, 0.035)          // ~4.6:1 on screen, alone
        val tall = TextBox("ABC-123", 0.40, 0.40, 0.05, 0.10)            // not plate-shaped
        val inSign = TextBox("ABC-123", 0.40, 0.20, 0.12, 0.035, linesInBlock = 6)   // one line of a big sign
        assertEquals(listOf(plate), PlateDetector.find(listOf(plate, tall, inSign), w, h))
    }
}
