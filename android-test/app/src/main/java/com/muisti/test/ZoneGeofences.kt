package com.muisti.test

import android.Manifest
import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.util.Log
import androidx.core.content.ContextCompat
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingEvent
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationServices
import com.muisti.privacy.Zone

/**
 * No-record zones as Play Services geofences: entering one stops capture even before the next per-frame check,
 * leaving it lets capture resume. The per-frame check on the latest fix (Zones.inside) stays as the second belt.
 */
object ZoneGeofences {
    /** Zone id the system says we are in (null = outside / unknown). */
    @Volatile var insideId: String? = null

    private fun pending(ctx: Context): PendingIntent = PendingIntent.getBroadcast(ctx, 7,
        Intent(ctx, ZoneGeofenceReceiver::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)

    @SuppressLint("MissingPermission")
    fun sync(ctx: Context, zones: List<Zone>) {
        val app = ctx.applicationContext
        if (ContextCompat.checkSelfPermission(app, Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) return
        val client = LocationServices.getGeofencingClient(app)
        client.removeGeofences(pending(app)).addOnCompleteListener {
            if (insideId != null && zones.none { it.id == insideId }) insideId = null
            if (zones.isEmpty()) return@addOnCompleteListener
            val req = GeofencingRequest.Builder()
                .setInitialTrigger(GeofencingRequest.INITIAL_TRIGGER_ENTER)
                .addGeofences(zones.take(100).map { z ->
                    Geofence.Builder().setRequestId(z.id).setCircularRegion(z.lat, z.lon, z.radiusM.toFloat())
                        .setExpirationDuration(Geofence.NEVER_EXPIRE)
                        .setTransitionTypes(Geofence.GEOFENCE_TRANSITION_ENTER or Geofence.GEOFENCE_TRANSITION_EXIT).build()
                }).build()
            client.addGeofences(req, pending(app))
                .addOnSuccessListener { Log.i("MuistiPrivacy", "geofences: ${zones.size} no-record zone(s) registered") }
                .addOnFailureListener { Log.w("MuistiPrivacy", "geofences not registered: ${it.message}") }
        }
    }
}

class ZoneGeofenceReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        val ev = GeofencingEvent.fromIntent(intent) ?: return
        if (ev.hasError()) return
        val id = ev.triggeringGeofences?.firstOrNull()?.requestId ?: return
        when (ev.geofenceTransition) {
            Geofence.GEOFENCE_TRANSITION_ENTER -> ZoneGeofences.insideId = id
            Geofence.GEOFENCE_TRANSITION_EXIT -> if (ZoneGeofences.insideId == id) ZoneGeofences.insideId = null
        }
        Log.i("MuistiPrivacy", "geofence ${if (ev.geofenceTransition == Geofence.GEOFENCE_TRANSITION_ENTER) "enter" else "exit"} zone $id")
    }
}
