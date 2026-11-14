package com.muisti.test

import android.annotation.SuppressLint
import android.content.Context
import android.location.Geocoder
import android.location.Location
import android.os.Build
import android.os.Looper
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import java.util.Locale

/** A GPS fix with the street it is on (if known). */
data class Fix(val lat: Double, val lon: Double, val accuracyM: Float, val timeMs: Long, val street: String?)

/**
 * Port of the iOS LocationProvider (Mustafa): GPS only while recording, best accuracy, no distance
 * filter (a standing user still gets fresh fixes), street name by reverse geocoding refreshed every
 * ~50 m, and only fresh fixes (< 10 s) are attached to a memory.
 */
class LocationTracker(private val ctx: Context) {
    private val client = LocationServices.getFusedLocationProviderClient(ctx)
    private val geocoder = if (Geocoder.isPresent()) Geocoder(ctx, Locale.US) else null
    @Volatile private var latest: Location? = null
    @Volatile private var street: String? = null
    private var lastGeocoded: Location? = null
    private var geocoding = false
    var running = false; private set

    private val callback = object : LocationCallback() {
        override fun onLocationResult(r: LocationResult) {
            val loc = r.lastLocation ?: return
            if (loc.accuracy > 100) return            // ignore very rough fixes
            latest = loc
            maybeGeocode(loc)
        }
    }

    @SuppressLint("MissingPermission")   // the caller checks ACCESS_FINE_LOCATION first
    fun start() {
        if (running) return
        val req = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 3000).setMinUpdateDistanceMeters(0f).build()
        client.requestLocationUpdates(req, callback, Looper.getMainLooper())
        running = true
    }

    fun stop() {
        client.removeLocationUpdates(callback)
        running = false
    }

    /** Latest fix if younger than [maxAgeMs] (iOS brief: no location older than 10 s). */
    fun fresh(maxAgeMs: Long = 10_000): Fix? {
        val l = latest ?: return null
        if (System.currentTimeMillis() - l.time > maxAgeMs) return null
        return Fix(l.latitude, l.longitude, l.accuracy, l.time, street)
    }

    private fun maybeGeocode(loc: Location) {
        val g = geocoder ?: return
        val last = lastGeocoded
        if (geocoding || (last != null && last.distanceTo(loc) < 50)) return
        geocoding = true
        lastGeocoded = loc
        val done = { name: String? -> if (name != null) street = name; geocoding = false }
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                g.getFromLocation(loc.latitude, loc.longitude, 1, object : Geocoder.GeocodeListener {
                    override fun onGeocode(list: MutableList<android.location.Address>) { done(list.firstOrNull()?.streetName()) }
                    override fun onError(msg: String?) { done(null) }
                })
            } else {
                Thread {
                    @Suppress("DEPRECATION")
                    done(runCatching { g.getFromLocation(loc.latitude, loc.longitude, 1)?.firstOrNull()?.streetName() }.getOrNull())
                }.start()
            }
        } catch (e: Exception) {
            done(null)
        }
    }

    private fun android.location.Address.streetName(): String? =
        listOfNotNull(thoroughfare, subLocality ?: locality).joinToString(", ").ifEmpty { null }
}
