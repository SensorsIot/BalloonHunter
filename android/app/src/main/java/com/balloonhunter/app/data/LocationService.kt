package com.balloonhunter.app.data

import android.annotation.SuppressLint
import android.content.Context
import android.location.Location
import com.balloonhunter.app.domain.models.LocationData
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.time.Instant

class LocationService(context: Context) {
    private val fusedClient = LocationServices.getFusedLocationProviderClient(context)
    private val _location = MutableStateFlow<LocationData?>(null)
    val location: StateFlow<LocationData?> = _location.asStateFlow()

    private var callback: com.google.android.gms.location.LocationCallback? = null

    @SuppressLint("MissingPermission")
    fun requestCurrentLocation() {
        fusedClient.getCurrentLocation(Priority.PRIORITY_HIGH_ACCURACY, null)
            .addOnSuccessListener { loc ->
                loc?.let { updateLocation(it) }
            }
    }

    @SuppressLint("MissingPermission")
    fun startBackgroundUpdates() {
        startUpdates(5000, Priority.PRIORITY_BALANCED_POWER_ACCURACY)
    }

    fun stopUpdates() {
        callback?.let { fusedClient.removeLocationUpdates(it) }
        callback = null
    }

    @SuppressLint("MissingPermission")
    private fun startUpdates(intervalMs: Long, priority: Int) {
        stopUpdates()
        val request = LocationRequest.Builder(priority, intervalMs)
            .setMinUpdateIntervalMillis(intervalMs)
            .build()
        val cb = object : com.google.android.gms.location.LocationCallback() {
            override fun onLocationResult(result: com.google.android.gms.location.LocationResult) {
                val location = result.lastLocation ?: return
                updateLocation(location)
            }
        }
        callback = cb
        fusedClient.requestLocationUpdates(request, cb, android.os.Looper.getMainLooper())
    }

    private fun updateLocation(location: Location) {
        _location.value = LocationData(
            latitude = location.latitude,
            longitude = location.longitude,
            altitude = location.altitude,
            horizontalAccuracy = location.accuracy.toDouble(),
            verticalAccuracy = location.verticalAccuracyMeters.toDouble(),
            heading = location.bearing.toDouble(),
            timestamp = Instant.ofEpochMilli(location.time)
        )
    }
}
