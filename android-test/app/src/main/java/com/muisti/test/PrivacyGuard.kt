package com.muisti.test

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import android.graphics.Bitmap
import org.json.JSONObject
import java.nio.FloatBuffer
import kotlin.math.exp

/**
 * Privacy gate: decides ON THE PHONE whether the camera is looking at something private,
 * before any frame is stored or sent to Nemotron.
 *
 *  1. Scene meaning (MobileCLIP-S0 image encoder, on-device): every frame is compared with short sentences
 *     ("a toilet in a bathroom", "a hand entering a PIN on an ATM keypad", "a street with shops", ...).
 *     The sentence vectors were computed once (tools/make_privacy_prompts.py); adding a situation = adding a sentence.
 *  2. Text on the frame (the OCR the phone already runs): card numbers (Luhn), IBAN, Finnish ID numbers,
 *     and PIN/password words when the scene also looks like a card, screen or document.
 *  3. Time: frames wait 3 s before they leave the phone, so the moment a private scene is detected the
 *     frames just before it are thrown away too. Hysteresis: it pauses fast and resumes only after the
 *     view has been clearly normal for a while.
 *
 * Two levels:
 *  - STOP  (bathroom, changing room, medical room): nothing is stored, nothing is sent, the live view is not
 *    available to the assistant; only the local check keeps running so it can resume by itself.
 *  - DROP  (ATM / PIN pad / card terminal, card, ID, banking screen): those frames are discarded, with a hangover.
 */
class PrivacyGuard(ctx: Context) {
    enum class Kind { STOP, DROP }
    enum class Event { ENTER, EXIT, UPGRADE }

    /** Probabilities summed per class over all of its sentences (softmax over every sentence). */
    data class Scores(val byClass: Map<String, Float>, val stop: Float, val pin: Float, val textual: Float,
                      val stopClass: String, val ms: Long) {
        val priv get() = stop + pin
    }

    private var session: OrtSession? = null
    private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
    private val prompts: List<Triple<String, String, FloatArray>>   // class, kind (stop|drop|safe), unit vector
    private val scale: Float
    private val size: Int
    var loadError: String? = null; private set

    init {
        val j = JSONObject(ctx.assets.open("privacy_prompts.json").bufferedReader().use { it.readText() })
        scale = j.optDouble("scale", 100.0).toFloat()
        size = j.optInt("size", 256)
        val arr = j.getJSONArray("prompts")
        prompts = (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            val v = o.getJSONArray("vec")
            Triple(o.getString("cls"), o.getString("kind"), FloatArray(v.length()) { v.getDouble(it).toFloat() })
        }
        session = runCatching {
            val bytes = ctx.assets.open(MODEL).use { it.readBytes() }
            env.createSession(bytes, OrtSession.SessionOptions().apply { setIntraOpNumThreads(2) })
        }.onFailure { loadError = "privacy model missing (${it.message?.take(60)})" }.getOrNull()
    }

    val available get() = session != null

    /** ~tens of ms on a phone CPU. Null when the model could not be loaded. */
    fun score(bmp: Bitmap): Scores? {
        val s = session ?: return null
        val t0 = System.currentTimeMillis()
        // CLIPFeatureExtractor: shortest edge -> 256, centre crop 256, RGB in 0..1, no mean/std normalisation
        val k = size.toFloat() / minOf(bmp.width, bmp.height)
        val scaled = Bitmap.createScaledBitmap(bmp, maxOf(size, Math.round(bmp.width * k)), maxOf(size, Math.round(bmp.height * k)), true)
        val crop = Bitmap.createBitmap(scaled, (scaled.width - size) / 2, (scaled.height - size) / 2, size, size)
        val px = IntArray(size * size)
        crop.getPixels(px, 0, size, 0, 0, size, size)
        val plane = size * size
        val input = FloatArray(3 * plane)
        for (i in 0 until plane) {
            val c = px[i]
            input[i] = (c shr 16 and 255) / 255f
            input[plane + i] = (c shr 8 and 255) / 255f
            input[2 * plane + i] = (c and 255) / 255f
        }
        val v = OnnxTensor.createTensor(env, FloatBuffer.wrap(input), longArrayOf(1, 3, size.toLong(), size.toLong())).use { x ->
            s.run(mapOf(s.inputNames.first() to x)).use { r ->
                @Suppress("UNCHECKED_CAST")
                (r[0].value as Array<FloatArray>)[0]
            }
        }
        var n = 0f
        for (f in v) n += f * f
        n = kotlin.math.sqrt(n)
        val logits = FloatArray(prompts.size) { i ->
            val p = prompts[i].third
            var d = 0f
            for (j in p.indices) d += p[j] * v[j]
            scale * d / n
        }
        val mx = logits.max()
        val e = FloatArray(logits.size) { exp(logits[it] - mx) }
        val sum = e.sum()
        val byClass = HashMap<String, Float>()
        for (i in prompts.indices) byClass.merge(prompts[i].first, e[i] / sum, Float::plus)
        val kindOf = prompts.associate { it.first to it.second }
        val stopClasses = byClass.filterKeys { kindOf[it] == "stop" }
        return Scores(byClass, stopClasses.values.sum(), byClass["pin"] ?: 0f,
            listOf("card", "document", "screen").sumOf { (byClass[it] ?: 0f).toDouble() }.toFloat(),
            stopClasses.maxByOrNull { it.value }?.key ?: "", System.currentTimeMillis() - t0)
    }

    // ---------------- state over time ----------------

    @Volatile var paused = false; private set
    @Volatile var kind: Kind? = null; private set
    @Volatile var reason: String? = null; private set
    @Volatile var lastScore = 0f; private set
    @Volatile var lastTextual = 0f; private set
    private var since = 0L
    private var lastHit = 0L
    private var hangover = 0L
    private var clean = 0
    private val recentStop = ArrayDeque<Float>()

    /** Feed every checked frame (~2 per second). Returns ENTER / EXIT / UPGRADE when the mode changes. */
    @Synchronized
    fun update(s: Scores, now: Long): Event? {
        lastScore = s.priv; lastTextual = s.textual
        recentStop.addLast(s.stop); while (recentStop.size > 3) recentStop.removeFirst()
        // a room: one very clear frame, or three fairly clear ones in a row (~1.5 s); a WC sign glimpsed in passing is not enough
        val stopNow = s.stop >= 0.8f || (recentStop.size == 3 && recentStop.all { it >= 0.6f })
        val pinNow = s.pin >= 0.7f
        if (stopNow) {
            val ev = if (!paused) Event.ENTER else if (kind != Kind.STOP) Event.UPGRADE else null
            enter(Kind.STOP, ROOM[s.stopClass] ?: "a private room", now, 0)
            return ev
        }
        if (pinNow) {
            val ev = if (!paused) Event.ENTER else null
            if (kind != Kind.STOP) enter(Kind.DROP, "a PIN pad or card terminal", now, 10_000)
            else lastHit = now
            return ev
        }
        if (!paused) return null
        // resume: the view must be clearly normal for several checks in a row (and a room needs a minimum pause)
        clean = if (s.priv < 0.3f) clean + 1 else 0
        val ok = when (kind) {
            Kind.STOP -> clean >= 6 && now - since >= 20_000
            else -> clean >= 3 && now - lastHit >= hangover
        }
        if (!ok) return null
        paused = false; kind = null; reason = null; clean = 0; recentStop.clear()
        return Event.EXIT
    }

    /** OCR found sensitive text on a frame (that frame is already dropped). Returns ENTER if this starts a pause. */
    @Synchronized
    fun textHit(why: String, now: Long): Event? {
        val ev = if (!paused) Event.ENTER else null
        if (kind != Kind.STOP) enter(Kind.DROP, why, now, 5_000) else lastHit = now
        return ev
    }

    private fun enter(k: Kind, why: String, now: Long, hang: Long) {
        if (!paused) since = now
        hangover = if (paused && kind == k) maxOf(hang, hangover) else hang
        paused = true; kind = k; reason = why; lastHit = now; clean = 0
    }

    companion object {
        const val MODEL = "mobileclip_s0_vision.onnx"
        private val ROOM = mapOf("bathroom" to "a bathroom", "changing" to "a changing room", "medical" to "a medical room")
    }
}

/** Sensitive text on a frame, from the phone's OCR. Strong patterns are checked arithmetically (Luhn, IBAN, HETU). */
object PrivacyText {
    private val digitsRun = Regex("""(?:\d[ -]?){13,19}""")
    private val iban = Regex("""\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30}\b""")
    private val hetu = Regex("""\b(\d{6})[-+ABCDEFUVWXY](\d{3})([0-9A-Y])\b""")
    private val words = Regex("""\b(pin|pin code|password|passcode|salasana|tunnusluku|cvv|cvc|passport|passi|henkilökortti|""" +
        """identity card|id card|account number|tilinumero|social security)\b""", RegexOption.IGNORE_CASE)

    /** Returns why the frame must not be kept, or null. [textual] = how much the scene looks like a card/screen/document. */
    fun check(lines: List<String>, textual: Float): String? {
        val all = lines.joinToString("\n")
        for (m in digitsRun.findAll(all)) {
            val d = m.value.filter { it.isDigit() }
            if (d.length in 13..19 && luhn(d)) return "a card number"
        }
        for (m in iban.findAll(all.uppercase())) if (ibanOk(m.value.replace(" ", ""))) return "a bank account number"
        for (m in hetu.findAll(all.uppercase())) if (hetuOk(m.groupValues[1], m.groupValues[2], m.groupValues[3])) return "a personal ID number"
        if (textual >= 0.35f && words.containsMatchIn(all)) return "a PIN, password or ID document"
        return null
    }

    private fun luhn(d: String): Boolean {
        var sum = 0
        for ((i, c) in d.reversed().withIndex()) {
            var x = c - '0'
            if (i % 2 == 1) { x *= 2; if (x > 9) x -= 9 }
            sum += x
        }
        return sum % 10 == 0 && d.toSet().size > 1      // "0000 0000 ..." is not a card
    }

    private fun ibanOk(s: String): Boolean {
        if (s.length !in 15..34) return false
        val r = s.substring(4) + s.substring(0, 4)
        var mod = 0
        for (c in r) {
            val v = if (c.isDigit()) c - '0' else if (c in 'A'..'Z') c - 'A' + 10 else return false
            mod = if (v >= 10) (mod * 100 + v) % 97 else (mod * 10 + v) % 97
        }
        return mod == 1
    }

    private fun hetuOk(date: String, num: String, check: String): Boolean {
        val n = (date + num).toLongOrNull() ?: return false
        return "0123456789ABCDEFHJKLMNPRSTUVWXY"[(n % 31).toInt()].toString() == check
    }
}
