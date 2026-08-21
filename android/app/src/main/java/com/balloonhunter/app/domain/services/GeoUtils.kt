package com.balloonhunter.app.domain.services

import com.balloonhunter.app.domain.models.GeoPoint
import kotlin.math.*

object GeoUtils {
    private const val EARTH_RADIUS_M = 6371000.0

    fun haversineMeters(a: GeoPoint, b: GeoPoint): Double {
        val dLat = Math.toRadians(b.latitude - a.latitude)
        val dLon = Math.toRadians(b.longitude - a.longitude)
        val lat1 = Math.toRadians(a.latitude)
        val lat2 = Math.toRadians(b.latitude)
        val sinLat = sin(dLat / 2)
        val sinLon = sin(dLon / 2)
        val h = sinLat * sinLat + cos(lat1) * cos(lat2) * sinLon * sinLon
        return 2 * EARTH_RADIUS_M * asin(min(1.0, sqrt(h)))
    }
}
