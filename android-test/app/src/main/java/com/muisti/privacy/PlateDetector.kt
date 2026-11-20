package com.muisti.privacy

/** One OCR line box in normalised image coordinates (0..1, top-left), as the phone's OCR returns it. */
data class TextBox(val text: String, val x: Double, val y: Double, val w: Double, val h: Double, val linesInBlock: Int = 1)

/**
 * Licence plates from the phone's own OCR boxes (no extra model): a short line that reads like a European plate,
 * with a plate-like aspect ratio, standing on its own (not one line of a sign with many lines).
 * Precision first: shop signs, prices, hours, phone numbers and room numbers must not be blurred.
 */
object PlateDetector {
    // letters groups of 1-3, digit groups of 1-4, at most 3 groups (FI ABC-123, SE ABC 12A, DE B-MW 1234, FR AB-123-CD,
    // IT AB 123 CD, UK AB12 CDE, EE 123 ABC); separators: space, hyphen, dot, middle dot
    private val shape = Regex("""^(?:[A-Z]{1,3}[ \-·.]?){1,2}\d{1,4}(?:[ \-·.]?[A-Z]{1,3})?$|^\d{1,4}[ \-·.]?[A-Z]{1,3}$|^[A-Z]{2}\d{2}[ ]?[A-Z]{3}$""")
    private val notPlateWords = Regex("""\b(MON|TUE|WED|THU|FRI|SAT|SUN|MA|TI|KE|TO|PE|LA|SU|AM|PM|EUR|KG|CM|MM|KM|MIN|NO|NR|TEL|PUH|BUS|WC|EXIT|LEVEL|ROOM|GATE|FLOOR|KRS|EXP|LOT|REF)\b""")

    /** True if this line of text could be a plate (text only). */
    fun looksLikePlate(text: String): Boolean {
        val t = text.trim().uppercase().replace(Regex("""\s+"""), " ")
        if (t.length !in 4..10) return false
        if (t.any { it in "€$£%:/,+()@&!?" }) return false            // prices, times, phone numbers, percentages
        if (notPlateWords.containsMatchIn(t) || Regex("[A-Z]{4,}").containsMatchIn(t)) return false   // words, not plate letter groups
        if (!shape.matches(t)) return false
        val alnum = t.filter { it.isLetterOrDigit() }
        val letters = alnum.count { it.isLetter() }; val digits = alnum.count { it.isDigit() }
        return alnum.length >= 5 && letters >= 2 && digits >= 1
    }

    /**
     * Plate boxes on an image of [imgW] x [imgH] pixels. Aspect = width/height in pixels: EU plates ~4.7, short
     * Nordic plates ~2.5-4 once OCR trims the margins.
     */
    fun find(boxes: List<TextBox>, imgW: Int, imgH: Int): List<TextBox> = boxes.filter { b ->
        val aspect = (b.w * imgW) / maxOf(1e-6, b.h * imgH)
        looksLikePlate(b.text) && aspect in 1.8..8.0 && b.linesInBlock <= 2 && b.h < 0.25
    }
}
