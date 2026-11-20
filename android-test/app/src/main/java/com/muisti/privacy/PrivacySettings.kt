package com.muisti.privacy

import org.json.JSONArray
import org.json.JSONObject

/** A circle on the map where nothing is recorded (centre + radius in metres). */
data class Zone(val id: String, val name: String, val lat: Double, val lon: Double, val radiusM: Double)

/** Progress of the one-time scan of memories stored before the privacy gate existed (resumable, see OldMemoryScan). */
data class ScanStatus(val lastScannedId: Int = 0, val total: Int = 0, val removed: Int = 0, val done: Boolean = false)

/**
 * What the user chose about privacy. Pure Kotlin (no Android types) so the rules are unit-tested.
 *
 * Team decision (Ömer, Nov 14): bathroom/toilet and nudity NEVER leave the phone and cannot be switched off;
 * POS terminals, PIN pads, cards and IBANs may go to Nemotron, so the sensitive-OCR block defaults to OFF.
 */
data class PrivacySettings(
    val activeClasses: Set<String> = LOCKED,
    val sensitiveOcr: Boolean = false,
    val plateBlur: Boolean = true,
    val zones: List<Zone> = emptyList(),
    val scan: ScanStatus = ScanStatus(),
) {
    /** Locked classes are always active, whatever was stored or requested. */
    fun normalized(): PrivacySettings =
        if (activeClasses.containsAll(LOCKED) && activeClasses.all { it in ALL_CLASSES }) this
        else copy(activeClasses = (activeClasses.filter { it in ALL_CLASSES } + LOCKED).toSet())

    /** Switch an optional class on or off. Locked classes ignore "off". */
    fun withClass(cls: String, on: Boolean): PrivacySettings {
        require(cls in ALL_CLASSES) { "unknown privacy class $cls" }
        val next = if (on) activeClasses + cls else activeClasses - cls
        return copy(activeClasses = next).normalized()
    }

    fun isActive(cls: String) = cls in activeClasses

    fun toJson(): String = JSONObject()
        .put("active", JSONArray(activeClasses.sorted()))
        .put("sensitiveOcr", sensitiveOcr)
        .put("plateBlur", plateBlur)
        .put("zones", JSONArray(zones.map { JSONObject().put("id", it.id).put("name", it.name).put("lat", it.lat).put("lon", it.lon).put("r", it.radiusM) }))
        .put("scan", JSONObject().put("last", scan.lastScannedId).put("total", scan.total).put("removed", scan.removed).put("done", scan.done))
        .toString()

    companion object {
        /** Never leave the phone, cannot be turned off. */
        val LOCKED = setOf("bathroom", "nudity")
        /** Stop-kind rooms the user may add (the camera pauses). */
        val OPTIONAL_STOP = listOf("changing", "medical")
        /** Drop-kind views the user may add (those frames are discarded). */
        val OPTIONAL_DROP = listOf("pin", "screen", "card", "document")
        val ALL_CLASSES = LOCKED + OPTIONAL_STOP + OPTIONAL_DROP
        val LABELS = mapOf(
            "bathroom" to "Bathrooms and toilets", "nudity" to "Nudity",
            "changing" to "Changing rooms", "medical" to "Medical rooms",
            "pin" to "ATMs, PIN pads, card terminals", "screen" to "Banking / password screens",
            "card" to "Bank cards and ID cards", "document" to "Letters and bills with personal details")

        /** Parses stored JSON; anything unreadable gives the defaults (which are the safe team decision). */
        fun fromJson(s: String?): PrivacySettings {
            if (s.isNullOrBlank()) return PrivacySettings()
            return runCatching {
                val j = JSONObject(s)
                val act = j.optJSONArray("active")?.let { a -> (0 until a.length()).map { a.getString(it) }.toSet() } ?: LOCKED
                val zs = j.optJSONArray("zones")?.let { a ->
                    (0 until a.length()).map { a.getJSONObject(it) }.map { z ->
                        Zone(z.getString("id"), z.optString("name", "Zone"), z.getDouble("lat"), z.getDouble("lon"), z.getDouble("r"))
                    }
                } ?: emptyList()
                val sc = j.optJSONObject("scan")?.let { ScanStatus(it.optInt("last"), it.optInt("total"), it.optInt("removed"), it.optBoolean("done")) } ?: ScanStatus()
                PrivacySettings(act, j.optBoolean("sensitiveOcr", false), j.optBoolean("plateBlur", true), zs, sc).normalized()
            }.getOrElse { PrivacySettings() }
        }
    }
}

/** Where the settings live (SharedPreferences on Android, a map in tests). */
interface KeyValueStore {
    fun get(key: String): String?
    fun put(key: String, value: String)
}

/** The single live copy of the settings: every reader (guard, OCR check, scan, zones) sees changes at once. */
class PrivacySettingsRepo(private val store: KeyValueStore) {
    @Volatile var current: PrivacySettings = PrivacySettings.fromJson(store.get(KEY)); private set
    private val listeners = java.util.concurrent.CopyOnWriteArrayList<(PrivacySettings) -> Unit>()

    fun update(f: (PrivacySettings) -> PrivacySettings): PrivacySettings = synchronized(this) {
        val next = f(current).normalized()
        current = next
        store.put(KEY, next.toJson())
        next
    }.also { s -> listeners.forEach { it(s) } }

    fun listen(l: (PrivacySettings) -> Unit) { listeners.add(l) }

    companion object { const val KEY = "privacy_settings_v1" }
}
