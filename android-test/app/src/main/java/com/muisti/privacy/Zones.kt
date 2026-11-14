package com.muisti.privacy

import kotlin.math.asin
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/** No-record zones: circles where nothing is captured. Pure Kotlin. */
object Zones {
    const val DEFAULT_RADIUS_M = 150.0

    /** Great-circle distance in metres. */
    fun distanceM(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val r = 6_371_000.0
        val dLat = Math.toRadians(lat2 - lat1); val dLon = Math.toRadians(lon2 - lon1)
        val a = sin(dLat / 2) * sin(dLat / 2) + cos(Math.toRadians(lat1)) * cos(Math.toRadians(lat2)) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(sqrt(a))
    }

    /**
     * The zone the user may be in, or null. Fail-safe towards privacy: a rough fix counts as inside when its
     * uncertainty circle reaches the zone (radius + accuracy, accuracy capped at 100 m so one bad fix cannot
     * block a whole city).
     */
    fun inside(lat: Double, lon: Double, accuracyM: Float?, zones: List<Zone>): Zone? =
        zones.firstOrNull { z -> distanceM(lat, lon, z.lat, z.lon) <= z.radiusM + minOf((accuracyM ?: 0f).toDouble(), 100.0) }

    fun newZone(name: String, lat: Double, lon: Double, radiusM: Double = DEFAULT_RADIUS_M) =
        Zone(java.util.UUID.randomUUID().toString().take(8), name.trim().ifEmpty { "Zone" }, lat, lon, radiusM.coerceIn(30.0, 2000.0))
}
