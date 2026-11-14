package com.muisti.capture

enum class Motion { STILL, WALKING, FAST, UNKNOWN }

/** Everything the scheduler looks at. Nulls = not known (no sensor, no glasses, no fix). */
data class CaptureSignals(
    val accRms: Double? = null,          // phone linear acceleration RMS over ~2 s, m/s²
    val gpsSpeed: Float? = null,         // m/s
    val gpsAccuracy: Float? = null,      // m
    val phoneBattery: Int? = null,       // %
    val powerSave: Boolean = false,
    val phoneThermal: Int = 0,           // PowerManager.THERMAL_STATUS_* (0 none .. 6 shutdown)
    val glassesBattery: Int? = null,     // %
    val glassesThermal: String? = null,  // SDK ThermalLevel name
)

data class CaptureDecision(val intervalMs: Long, val motion: Motion, val factor: Double, val paused: Boolean, val reason: String)

/**
 * Decides how long each capture window is (the sharpest frame of a window is kept), port of the iOS
 * AdaptiveScheduler idea for Android sensors:
 *
 * | state    | base window | notes                                                     |
 * |----------|-------------|-----------------------------------------------------------|
 * | fast     | 1000 ms     | bike / car / GPS > 4 m/s                                   |
 * | walking  | 1000 ms     |                                                           |
 * | unknown  | 1500 ms     | no sensor data                                            |
 * | still    | 3000 ms     | 7500 ms after 12 still windows with an unchanged view     |
 * A head turn (view changed a lot since the last kept frame) counts as moving for the next window.
 *
 * Factors (multiplied): phone power-save or battery < 20 % ×1.5; glasses battery < 10 % ×3, < 20 % ×2;
 * phone thermal MODERATE or glasses hot ×2. Phone thermal >= SEVERE or glasses CRITICAL+: capture pauses
 * (shown in the UI). Windows are never shorter than 500 ms.
 */
class CaptureScheduler {
    private var stillRuns = 0
    private var viewMoved = false

    companion object {
        const val THERMAL_MODERATE = 2
        const val THERMAL_SEVERE = 3
        private val HOT = setOf("SEVERE", "MODERATE")
        private val TOO_HOT = setOf("CRITICAL", "EMERGENCY", "SHUTDOWN")

        fun classify(s: CaptureSignals): Motion {
            val trustedGps = s.gpsSpeed != null && (s.gpsAccuracy ?: 99f) <= 20f
            return when {
                trustedGps && s.gpsSpeed!! > 4f -> Motion.FAST
                s.accRms == null && !trustedGps -> Motion.UNKNOWN
                (s.accRms ?: 0.0) >= 0.6 -> Motion.WALKING
                trustedGps && s.gpsSpeed!! > 1f -> Motion.WALKING
                else -> Motion.STILL
            }
        }
    }

    /** The bits of dHash that changed between the last two kept frames: a big change is a head turn. */
    fun onKept(bitsChanged: Int) { viewMoved = bitsChanged >= 20; if (viewMoved) stillRuns = 0 }

    fun decide(s: CaptureSignals): CaptureDecision {
        val motion = classify(s)
        if (s.phoneThermal >= THERMAL_SEVERE) return CaptureDecision(0, motion, 0.0, true, "phone is too hot")
        if (s.glassesThermal in TOO_HOT) return CaptureDecision(0, motion, 0.0, true, "glasses are too hot")
        var f = 1.0
        if (s.powerSave || (s.phoneBattery ?: 100) < 20) f *= 1.5
        s.glassesBattery?.let { if (it < 10) f *= 3.0 else if (it < 20) f *= 2.0 }
        if (s.phoneThermal >= THERMAL_MODERATE || s.glassesThermal in HOT) f *= 2.0
        val effective = if (motion == Motion.STILL && viewMoved) Motion.WALKING else motion
        val base = when (effective) {
            Motion.FAST, Motion.WALKING -> { stillRuns = 0; 1000L }
            Motion.UNKNOWN -> 1500L
            Motion.STILL -> if (++stillRuns > 12) 7500L else 3000L
        }
        viewMoved = false
        val why = buildString {
            append(effective.name.lowercase())
            if (f > 1.0) append(", ×%.1f (%s)".format(f, listOfNotNull(
                "power save / low battery".takeIf { s.powerSave || (s.phoneBattery ?: 100) < 20 },
                "glasses battery".takeIf { (s.glassesBattery ?: 100) < 20 },
                "warm".takeIf { s.phoneThermal >= THERMAL_MODERATE || s.glassesThermal in HOT }).joinToString(", ")))
        }
        return CaptureDecision(maxOf(500L, (base * f).toLong()), effective, f, false, why)
    }
}
