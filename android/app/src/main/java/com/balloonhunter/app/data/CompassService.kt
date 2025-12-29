package com.balloonhunter.app.data

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Provides device compass heading using rotation vector sensor.
 * Heading is in degrees from north (0-360), where:
 * - 0/360 = North
 * - 90 = East
 * - 180 = South
 * - 270 = West
 */
class CompassService(context: Context) : SensorEventListener {
    private val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val rotationSensor = sensorManager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)

    private val _heading = MutableStateFlow(0f)
    val heading: StateFlow<Float> = _heading.asStateFlow()

    private val _isAvailable = MutableStateFlow(rotationSensor != null)
    val isAvailable: StateFlow<Boolean> = _isAvailable.asStateFlow()

    private var isListening = false
    private val rotationMatrix = FloatArray(9)
    private val orientation = FloatArray(3)
    private var lastHeading = 0f

    fun startListening() {
        if (isListening || rotationSensor == null) return
        sensorManager.registerListener(
            this,
            rotationSensor,
            SensorManager.SENSOR_DELAY_GAME // Faster updates (~20ms) for responsive compass
        )
        isListening = true
    }

    fun stopListening() {
        if (!isListening) return
        sensorManager.unregisterListener(this)
        isListening = false
    }

    override fun onSensorChanged(event: SensorEvent) {
        if (event.sensor.type != Sensor.TYPE_ROTATION_VECTOR) return

        // Get rotation matrix from sensor
        SensorManager.getRotationMatrixFromVector(rotationMatrix, event.values)

        // Get orientation angles
        SensorManager.getOrientation(rotationMatrix, orientation)

        // Convert azimuth from radians to degrees
        // Azimuth is orientation[0], range is -PI to PI
        var azimuthDegrees = Math.toDegrees(orientation[0].toDouble()).toFloat()

        // Normalize to 0-360
        if (azimuthDegrees < 0) {
            azimuthDegrees += 360f
        }

        // Apply low-pass filter for smooth rotation without jitter
        // Handle wraparound at 0/360 boundary
        var delta = azimuthDegrees - lastHeading
        if (delta > 180f) delta -= 360f
        if (delta < -180f) delta += 360f

        // Smoothing factor: 0.3 = responsive yet smooth (lower = smoother but laggier)
        val smoothedHeading = lastHeading + delta * 0.3f

        // Normalize smoothed heading to 0-360
        val normalizedHeading = ((smoothedHeading % 360f) + 360f) % 360f
        lastHeading = normalizedHeading

        _heading.value = normalizedHeading
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
        // Could track accuracy if needed
    }
}
