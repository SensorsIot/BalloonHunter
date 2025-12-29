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

    fun startListening() {
        if (isListening || rotationSensor == null) return
        sensorManager.registerListener(
            this,
            rotationSensor,
            SensorManager.SENSOR_DELAY_UI
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

        _heading.value = azimuthDegrees
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
        // Could track accuracy if needed
    }
}
