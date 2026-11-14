package com.muisti.privacy

/**
 * Turns the on-phone scene model's per-class probabilities into a decision, using the user's settings.
 * Pure Kotlin: the same rules run on the phone and in the JVM tests.
 */
object SceneRules {
    /** Class -> kind ("stop" | "drop" | "safe"), as in tools/make_privacy_prompts.py. */
    val KIND = mapOf(
        "bathroom" to "stop", "changing" to "stop", "nudity" to "stop", "medical" to "stop",
        "pin" to "drop", "screen" to "drop", "card" to "drop", "document" to "drop")

    const val BLOCK = 0.7f

    class Summary(val stop: Float, val drop: Float, val stopClass: String, val dropClass: String, val textual: Float, val keypad: Float)

    /** Only ACTIVE classes count towards stop / drop; textual and keypad hints are always computed (OCR uses them). */
    fun summarize(byClass: Map<String, Float>, s: PrivacySettings): Summary {
        val stop = byClass.filterKeys { KIND[it] == "stop" && s.isActive(it) }
        val drop = byClass.filterKeys { KIND[it] == "drop" && s.isActive(it) }
        return Summary(stop.values.sum(), drop.values.sum(),
            stop.maxByOrNull { it.value }?.key ?: "", drop.maxByOrNull { it.value }?.key ?: "",
            listOf("card", "document", "screen").sumOf { (byClass[it] ?: 0f).toDouble() }.toFloat(),
            byClass["pin"] ?: 0f)
    }

    /** One picture judged on its own (import, network exit, old memories). Null = may leave the phone. */
    fun blockReason(byClass: Map<String, Float>, s: PrivacySettings): String? {
        val m = summarize(byClass, s)
        if (m.stop >= BLOCK) return "a private place (${m.stopClass})"
        if (m.drop >= BLOCK) return PrivacySettings.LABELS[m.dropClass]?.lowercase() ?: m.dropClass
        return null
    }
}

/** Scene hints for text checks: how much the view looks like a card/document/screen, and like a keypad. */
data class SceneHint(val textual: Float = 0f, val keypad: Float = 0f)

/**
 * Sensitive text on a frame, from the phone's OCR. Strong patterns are checked arithmetically:
 * card numbers (Luhn + issuer prefix), IBAN (mod 97), Finnish personal ID (HETU check character), passport/ID
 * machine-readable zones. Words (PIN, password, ID card) only count together with a matching scene.
 * Off by default (team decision); the setting "Block frames with card numbers / IBAN / ID numbers / PINs" turns it on.
 */
object PrivacyText {
    /** Reads the live setting; replaced by the app at start (tests set it directly). */
    @Volatile var enabledProvider: () -> Boolean = { false }
    val enabled get() = enabledProvider()

    private val groupedCard = Regex("""(?<!\d)(\d{4}[ -]\d{4}[ -]\d{4}[ -]\d{1,7}|\d{4}[ -]\d{6}[ -]\d{5})(?!\d)""")
    private val digitRun = Regex("""(?<!\d)\d{13,19}(?!\d)""")
    private val cardContext = Regex("""\b(visa|mastercard|maestro|amex|american express|debit|credit|card|kortti|valid thru|valid until|voimassa|exp|cvv|cvc)\b|\b(0[1-9]|1[0-2])\s?/\s?\d{2}\b""", RegexOption.IGNORE_CASE)
    private val iban = Regex("""\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30}\b""")
    private val hetu = Regex("""\b(\d{6})[-+ABCDEFUVWXY](\d{3})([0-9A-Y])\b""")
    private val mrz = Regex("""^[PIAC][A-Z<][A-Z]{3}[A-Z0-9<]{20,}$""")
    private val pinWords = Regex("""\b(pin|pin code|pin-koodi|tunnusluku|syötä tunnusluku|enter pin|cvv|cvc)\b""", RegexOption.IGNORE_CASE)
    private val secretWords = Regex("""\b(password|passcode|salasana|lösenord|account number|tilinumero|social security)\b""", RegexOption.IGNORE_CASE)
    private val idWords = Regex("""\b(henkilökortti|identitetskort|identity card|id card|personalausweis|carte d'identité|passport|passi|ajokortti|driving licen[cs]e|residence permit|oleskelulupa|henkilötunnus|personbeteckning)\b""", RegexOption.IGNORE_CASE)
    private val birthDate = Regex("""\b(0?[1-9]|[12]\d|3[01])[./ ](0?[1-9]|1[0-2])[./ ](19|20)\d{2}\b""")
    private val docNumber = Regex("""\b(no|nro|number|numero|document)\.?\s*:?\s*[A-Z]{0,3}\d{6,9}\b""", RegexOption.IGNORE_CASE)

    /** Why the frame must not leave the phone, or null. Respects the setting. */
    fun check(lines: List<String>, hint: SceneHint): String? = if (!enabled) null else find(lines, hint)

    /** The rules themselves, regardless of the setting. */
    fun find(lines0: List<String>, hint: SceneHint): String? {
        val lines = lines0.map { it.trim() }.filter { it.isNotEmpty() }
        val all = lines.joinToString("\n")
        // neighbouring lines joined: a card number or IBAN that OCR split over two lines
        val pairs = lines.zipWithNext { a, b -> "$a $b" }
        val context = cardContext.containsMatchIn(all)
        for (text in lines + pairs) {
            for (m in groupedCard.findAll(text)) if (isCard(m.value.filter { it.isDigit() })) return "a card number"
            if (context) for (m in digitRun.findAll(text)) if (isCard(m.value)) return "a card number"
        }
        for (text in lines + pairs) for (m in iban.findAll(text.uppercase())) if (ibanOk(m.value.replace(" ", ""))) return "a bank account number"
        for (m in hetu.findAll(all.uppercase())) if (hetuOk(m.groupValues[1], m.groupValues[2], m.groupValues[3])) return "a personal ID number"
        if (lines.any { mrz.matches(it.replace(" ", "").uppercase()) && it.count { c -> c == '<' } >= 5 }) return "an ID document"
        if (idWords.containsMatchIn(all) && (hint.textual >= 0.35f || birthDate.containsMatchIn(all) || docNumber.containsMatchIn(all))) return "an ID document"
        if (pinWords.containsMatchIn(all) && hint.keypad >= 0.35f) return "a PIN entry"
        if (secretWords.containsMatchIn(all) && hint.textual >= 0.35f) return "a password or account number"
        return null
    }

    /** Luhn + a real issuer prefix (2-6) + not all one digit. */
    fun isCard(d: String): Boolean {
        if (d.length !in 13..19 || d[0] !in '2'..'6' || d.toSet().size <= 1) return false
        var sum = 0
        for ((i, c) in d.reversed().withIndex()) {
            var x = c - '0'
            if (i % 2 == 1) { x *= 2; if (x > 9) x -= 9 }
            sum += x
        }
        return sum % 10 == 0
    }

    fun ibanOk(s: String): Boolean {
        if (s.length !in 15..34 || !s.substring(0, 2).all { it in 'A'..'Z' }) return false
        val r = s.substring(4) + s.substring(0, 4)
        var mod = 0
        for (c in r) {
            val v = if (c.isDigit()) c - '0' else if (c in 'A'..'Z') c - 'A' + 10 else return false
            mod = if (v >= 10) (mod * 100 + v) % 97 else (mod * 10 + v) % 97
        }
        return mod == 1
    }

    fun hetuOk(date: String, num: String, check: String): Boolean {
        val n = (date + num).toLongOrNull() ?: return false
        val dd = date.substring(0, 2).toInt(); val mm = date.substring(2, 4).toInt()
        if (dd !in 1..31 || mm !in 1..12) return false
        return "0123456789ABCDEFHJKLMNPRSTUVWXY"[(n % 31).toInt()].toString() == check
    }
}
