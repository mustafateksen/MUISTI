package com.muisti.capture

/** What the Meta Wearables SDK reports about one pair of glasses (copied out of the SDK's Device, so this is testable). */
data class GlassesInfo(val name: String, val link: String, val compatibility: String, val hinge: String,
                       val don: String, val battery: Int, val thermal: String)

/**
 * The status line shown while connecting to the glasses, decided ONLY from the SDK's own state (defect D5: the app
 * used to say "Waiting…" whatever the cause). The important case: Meta AI says this app is REGISTERED but its device
 * list stays empty — Meta AI's channel to the app is stuck, and only restarting the glasses and Meta AI fixes it.
 */
object GlassesHint {
    const val STUCK_AFTER_MS = 10_000L

    fun describe(registration: String, devices: List<GlassesInfo>, waitedMs: Long): String {
        if (registration != "REGISTERED") return when (registration) {
            "REGISTERING" -> "Registering with Meta AI…"
            "UNAVAILABLE" -> "Meta AI isn't available on this phone (install or update Meta AI)"
            else -> "Not registered with Meta AI yet (${registration.lowercase()})"
        }
        val d = devices.firstOrNull { it.link == "CONNECTED" } ?: devices.firstOrNull()
        if (d == null) return if (waitedMs < STUCK_AFTER_MS) "Meta AI is registered, looking for your glasses…"
            else "Meta AI reports no glasses for this app. If Meta AI shows them connected, its link to MUISTI is stuck: " +
                "restart the glasses and force-stop Meta AI, then tap Try again."
        val extra = listOfNotNull(
            d.battery.takeIf { it in 0..15 }?.let { "battery $it%" },
            d.thermal.takeIf { it in setOf("SEVERE", "CRITICAL", "EMERGENCY", "SHUTDOWN") }?.let { "glasses are hot" },
        ).joinToString(", ").let { if (it.isEmpty()) "" else " ($it)" }
        return when {
            d.compatibility == "DEVICE_UPDATE_REQUIRED" -> "${d.name}: needs an update in Meta AI"
            d.compatibility == "SDK_UPDATE_REQUIRED" -> "${d.name}: this app's glasses SDK is too old for them"
            d.hinge == "CLOSED" -> "${d.name}: folded - unfold them$extra"
            d.link == "DISCONNECTED" -> "${d.name}: not connected over Bluetooth - check Meta AI$extra"
            d.link == "CONNECTING" -> "${d.name}: connecting…$extra"
            d.don == "DOFFED" -> "${d.name}: connected, put them on to start$extra"
            else -> "${d.name}: connected$extra"
        }
    }
}
