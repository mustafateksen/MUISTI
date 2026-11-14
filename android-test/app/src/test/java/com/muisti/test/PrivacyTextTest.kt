package com.muisti.test

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PrivacyTextTest {
    @Test
    fun strongPatterns() {
        assertEquals("a card number", PrivacyText.check(listOf("VISA", "4111 1111 1111 1111", "12/28"), 0f))
        assertEquals("a bank account number", PrivacyText.check(listOf("IBAN FI21 1234 5600 0007 85"), 0f))
        assertEquals("a personal ID number", PrivacyText.check(listOf("Henkilötunnus 131052-308T"), 0f))
    }

    @Test
    fun weakWordsNeedACardOrScreenScene() {
        assertEquals("a PIN, password or ID document", PrivacyText.check(listOf("Enter your PIN"), 0.6f))
        assertNull(PrivacyText.check(listOf("Enter your PIN"), 0.1f))
    }

    @Test
    fun normalSignsPass() {
        assertNull(PrivacyText.check(listOf("Kampin Apteekki", "Avoinna ma-pe 8-20", "puh. 09 1234 5678"), 0.6f))
        assertNull(PrivacyText.check(listOf("Order 1234 5678 9012 3456"), 0f))   // 16 digits but not Luhn-valid
        assertNull(PrivacyText.check(listOf("WC 2. KERROKSESSA", "HISSI EPÄKUNNOSSA"), 0.3f))
    }
}
