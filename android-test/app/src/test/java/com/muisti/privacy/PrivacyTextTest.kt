package com.muisti.privacy

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/** P1.2: >= 15 frames that must be blocked, >= 15 everyday frames that must pass (rules only, setting ignored). */
class PrivacyTextTest {
    private val none = SceneHint()
    private val cardScene = SceneHint(textual = 0.6f)
    private val keypad = SceneHint(keypad = 0.6f)

    private val positives: List<Pair<List<String>, SceneHint>> = listOf(
        listOf("VISA", "4111 1111 1111 1111", "12/28") to none,
        listOf("5555 5555 5555 4444") to none,                                  // grouped 4-4-4-4: Luhn is enough
        listOf("AMERICAN EXPRESS", "3782 822463 10005") to none,                // Amex 4-6-5
        listOf("Mastercard", "2223003122003222") to none,                       // contiguous + card word
        listOf("6011 1111", "1111 1117") to none,                               // split over two OCR lines
        listOf("4012 8888 8888", "1881 VALID THRU 09/27") to none,              // split, second line has more text
        listOf("Debit 4012888888881881") to none,
        listOf("IBAN FI21 1234 5600 0007 85") to none,
        listOf("Tilinumero:", "FI21 1234 5600", "0007 85") to none,             // IBAN split over two lines
        listOf("DE89 3704 0044 0532 0130 00") to none,
        listOf("GB29NWBK60161331926819") to none,
        listOf("Henkilötunnus 131052-308T") to none,
        listOf("HETU: 150399-123L") to none,
        listOf("P<FINVIRTANEN<<MATTI<JUHANI<<<<<<<<<<<<<<<<<") to none,          // passport MRZ
        listOf("HENKILÖKORTTI", "IDENTITETSKORT", "Syntymäaika 01.05.1994") to none,
        listOf("PASSPORT", "No. XP1234567") to none,
        listOf("Enter your PIN") to keypad,
        listOf("Syötä tunnusluku") to keypad,
        listOf("Salasana: kissa123") to cardScene,
    )

    private val negatives: List<Pair<List<String>, SceneHint>> = listOf(
        listOf("Kampin Apteekki", "Avoinna ma-pe 8-20", "puh. 09 1234 5678") to cardScene,
        listOf("+358 40 123 4567", "+358 50 765 4321") to none,                 // two phone numbers on adjacent lines
        listOf("Order 1234 5678 9012 3456") to none,                            // 16 digits, not Luhn-valid
        listOf("Tilausnumero 1234567890123456") to none,
        listOf("6 410405 082657") to none,                                      // EAN-13 barcode, Luhn-valid by chance
        listOf("6410405082657") to none,
        listOf("Maito 1,89 €", "Ruisleipä 2,49 €", "Yhteensä 4,38") to none,
        listOf("Ma-Pe 7-18, La 9-15") to none,
        listOf("Bus 14 / 24 / Kamppi 3 min") to none,
        listOf("WC 2. KERROKSESSA", "HISSI EPÄKUNNOSSA") to cardScene,
        listOf("Y-tunnus 1234567-8") to none,                                   // business ID, not a person
        listOf("Passport control", "Passitarkastus") to none,                  // airport sign: no ID scene, no date
        listOf("PIN code required for card payments") to none,                 // poster: not a keypad scene
        listOf("Enter your PIN") to SceneHint(keypad = 0.1f),
        listOf("Password manager workshop 14:00") to none,
        listOf("Final demos Sunday 15 November 14:00") to none,
        listOf("Ref. FI 2112 3456") to none,                                    // short, not an IBAN
        listOf("Lot 20261114 Best before 30.11.2026") to none,
        listOf("Kassa 3", "Kuitti 0042-1234-5678") to none,
    )

    @Test
    fun blocksSensitiveFrames() {
        assert(positives.size >= 15)
        for ((lines, hint) in positives) assertNotNull("should block: $lines", PrivacyText.find(lines, hint))
    }

    @Test
    fun everydayFramesPass() {
        assert(negatives.size >= 15)
        for ((lines, hint) in negatives) assertNull("should pass: $lines", PrivacyText.find(lines, hint))
    }

    @Test
    fun reasons() {
        assertEquals("a card number", PrivacyText.find(listOf("VISA", "4111 1111 1111 1111"), none))
        assertEquals("a bank account number", PrivacyText.find(listOf("IBAN FI21 1234 5600 0007 85"), none))
        assertEquals("a personal ID number", PrivacyText.find(listOf("Henkilötunnus 131052-308T"), none))
    }

    @Test
    fun settingGatesTheCheck() {
        val card = listOf("4111 1111 1111 1111")
        PrivacyText.enabledProvider = { false }
        assertNull("off by default (team decision): stored", PrivacyText.check(card, none))
        PrivacyText.enabledProvider = { true }
        assertEquals("a card number", PrivacyText.check(card, none))
        PrivacyText.enabledProvider = { false }
    }
}
