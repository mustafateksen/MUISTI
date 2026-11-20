package com.muisti.test

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import kotlin.math.sqrt

/**
 * Phone motion for the capture scheduler: RMS of linear acceleration (gravity removed), smoothed over ~2 s
 * (rises at once, decays 0.95/0.05 like the iOS head-bob meter). Runs only while recording.
 */
class MotionMeter(ctx: Context) : SensorEventListener {
    private val sm = ctx.getSystemService(SensorManager::class.java)
    private val sensor = sm?.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION)
    @Volatile private var rms: Double? = null
    @Volatile private var lastAt = 0L

    fun start() { sensor?.let { sm?.registerListener(this, it, SensorManager.SENSOR_DELAY_UI) } }
    fun stop() { sm?.unregisterListener(this); rms = null }

    /** Smoothed RMS in m/s², or null without a sensor / fresh data. */
    fun rms(): Double? = rms?.takeIf { System.currentTimeMillis() - lastAt < 3000 }

    override fun onSensorChanged(e: SensorEvent) {
        val m = sqrt((e.values[0] * e.values[0] + e.values[1] * e.values[1] + e.values[2] * e.values[2]).toDouble())
        val r = rms ?: m
        rms = if (m > r) m else 0.95 * r + 0.05 * m
        lastAt = System.currentTimeMillis()
    }

    override fun onAccuracyChanged(s: Sensor?, a: Int) {}
}
