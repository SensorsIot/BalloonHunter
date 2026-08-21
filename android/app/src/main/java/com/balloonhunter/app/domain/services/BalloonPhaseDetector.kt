package com.balloonhunter.app.domain.services

import com.balloonhunter.app.domain.models.BalloonPhase
import com.balloonhunter.app.domain.models.BalloonTrackPoint
import com.balloonhunter.app.domain.models.PositionData
import com.balloonhunter.app.domain.models.TelemetrySource
import java.time.Duration
import java.time.Instant
import kotlin.math.abs

object BalloonPhaseDetector {
    fun determinePhase(
        position: PositionData?,
        track: List<BalloonTrackPoint>,
        trackBasedLandingDetected: Boolean
    ): BalloonPhase {
        if (trackBasedLandingDetected) return BalloonPhase.LANDED
        if (position == null) return BalloonPhase.UNKNOWN

        if (position.telemetrySource == TelemetrySource.APRS) {
            val ageSeconds = Duration.between(position.timestamp, Instant.now()).seconds
            if (ageSeconds > 120) return BalloonPhase.LANDED
        }

        if (position.telemetrySource == TelemetrySource.BLE) {
            val landed = detectNetMovementLanding(track)
            if (landed) return BalloonPhase.LANDED
        }

        val vSpeed = position.verticalSpeed
        return when {
            vSpeed > 0 -> BalloonPhase.ASCENDING
            vSpeed < 0 -> if (position.altitude > 10000) BalloonPhase.DESCENDING_ABOVE_10K else BalloonPhase.DESCENDING_BELOW_10K
            else -> BalloonPhase.UNKNOWN
        }
    }

    private fun detectNetMovementLanding(track: List<BalloonTrackPoint>): Boolean {
        if (track.size < 5) return false
        val window = track.takeLast(minOf(20, track.size))
        val first = window.first()
        val last = window.last()
        val dt = Duration.between(first.timestamp, last.timestamp).seconds.toDouble().coerceAtLeast(1.0)
        val displacement = GeoUtils.haversineMeters(first.point, last.point)
        val altitudeDelta = abs(last.altitude - first.altitude)
        val netSpeed = kotlin.math.sqrt(displacement * displacement + altitudeDelta * altitudeDelta) / dt
        return netSpeed < 0.83 && last.altitude < 3000
    }
}
