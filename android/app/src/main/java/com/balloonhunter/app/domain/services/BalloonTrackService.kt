package com.balloonhunter.app.domain.services

import com.balloonhunter.app.domain.models.BalloonMotionMetrics
import com.balloonhunter.app.domain.models.BalloonTrackPoint
import com.balloonhunter.app.domain.models.DataState
import com.balloonhunter.app.domain.models.PositionData
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.time.Duration
import java.time.Instant
import android.util.Log
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

private const val TAG = "debugAPRS"
private const val TAG_FILTER = "TrackFilter"

/**
 * Track service - memory only, no database persistence.
 * Track data is fetched from SondeHub API on startup/sonde change.
 */
class BalloonTrackService {
    private var notificationSink: TrackNotificationSink? = null

    fun setNotificationSink(sink: TrackNotificationSink) {
        this.notificationSink = sink
    }
    private val _track = MutableStateFlow<List<BalloonTrackPoint>>(emptyList())
    val track: StateFlow<List<BalloonTrackPoint>> = _track.asStateFlow()

    private val _motionMetrics = MutableStateFlow<BalloonMotionMetrics?>(null)
    val motionMetrics: StateFlow<BalloonMotionMetrics?> = _motionMetrics.asStateFlow()

    private val _adjustedDescentRate = MutableStateFlow<Double?>(null)
    val adjustedDescentRate: StateFlow<Double?> = _adjustedDescentRate.asStateFlow()

    private val _trackBasedLandingDetected = MutableStateFlow(false)
    val trackBasedLandingDetected: StateFlow<Boolean> = _trackBasedLandingDetected.asStateFlow()

    private val horizFilter = HampelFilter(10, 3.0)
    private val vertFilter = HampelFilter(10, 3.0)
    private val horizEmaFast = EmaFilter(3.0)
    private val vertEmaFast = EmaFilter(3.0)
    private val vertEmaSlow = EmaFilter(30.0)

    private val descentRateHistory = ArrayDeque<Double>()

    fun recordPoint(position: PositionData, state: DataState) {
        // When landed, set speeds to zero
        if (state == DataState.APRS_LANDED || state == DataState.LIVE_BLE_LANDED) {
            _motionMetrics.value = BalloonMotionMetrics(
                rawHorizontalSpeedMS = 0.0,
                rawVerticalSpeedMS = 0.0,
                smoothedHorizontalSpeedMS = 0.0,
                smoothedVerticalSpeedMS = 0.0,
                adjustedDescentRateMS = 0.0
            )
            return
        }

        if (state == DataState.STARTUP || state == DataState.WAITING_FOR_APRS ||
            state == DataState.NO_TELEMETRY
        ) {
            return
        }

        val timestamp = position.timestamp
        val seconds = timestamp.epochSecond
        val existing = _track.value
        if (existing.any { it.timestamp.epochSecond == seconds }) return

        val last = existing.lastOrNull()
        val horizontalSpeed = if (last != null) {
            val distance = GeoUtils.haversineMeters(last.point, position.point)
            val dt = Duration.between(last.timestamp, timestamp).seconds.toDouble().coerceAtLeast(1.0)
            distance / dt
        } else {
            position.horizontalSpeed
        }

        val verticalSpeed = if (last != null) {
            val dt = Duration.between(last.timestamp, timestamp).seconds.toDouble().coerceAtLeast(1.0)
            (position.altitude - last.altitude) / dt
        } else {
            position.verticalSpeed
        }

        val point = BalloonTrackPoint(
            latitude = position.latitude,
            longitude = position.longitude,
            altitude = position.altitude,
            timestamp = timestamp,
            verticalSpeed = verticalSpeed,
            horizontalSpeed = horizontalSpeed
        )

        val sorted = (existing + point).sortedBy { it.timestamp }
        val updated = filterImpossibleJumps(sorted)
        _track.value = updated

        updateMotionMetrics(horizontalSpeed, verticalSpeed, timestamp)
        updateAdjustedDescentRate(updated)
        detectTrackBasedLanding(updated)
    }

    fun clearTrack() {
        Log.d(TAG, "clearTrack: clearing ${_track.value.size} points from memory")
        _track.value = emptyList()
        _trackBasedLandingDetected.value = false
    }

    fun insertGapFill(points: List<BalloonTrackPoint>) {
        if (points.isEmpty()) return
        Log.d(TAG, "insertGapFill: REPLACING track with ${points.size} gap fill points (was ${_track.value.size})")
        points.firstOrNull()?.let { first ->
            Log.d(TAG, "insertGapFill: first point lat=${first.latitude}, lon=${first.longitude}, alt=${first.altitude}")
        }
        points.lastOrNull()?.let { last ->
            Log.d(TAG, "insertGapFill: last point lat=${last.latitude}, lon=${last.longitude}, alt=${last.altitude}")
        }
        // Replace track entirely with gap fill data (don't merge with potentially stale persisted data)
        val deduped = points.associateBy { it.timestamp.epochSecond }
        val sorted = deduped.values.sortedBy { it.timestamp }
        _track.value = filterImpossibleJumps(sorted.toList())
        Log.d(TAG, "insertGapFill: track now has ${_track.value.size} points (filtered from ${sorted.size})")
    }

    private fun updateMotionMetrics(rawHorizontal: Double, rawVertical: Double, timestamp: Instant) {
        val filteredHoriz = horizFilter.filter(rawHorizontal)
        val filteredVert = vertFilter.filter(rawVertical)

        val deadbandHoriz = if (abs(filteredHoriz) < 0.2) 0.0 else filteredHoriz
        val deadbandVert = if (abs(filteredVert) < 0.05) 0.0 else filteredVert

        val smoothHoriz = horizEmaFast.update(deadbandHoriz, timestamp)
        val smoothVert = vertEmaFast.update(deadbandVert, timestamp)
        val slowVert = vertEmaSlow.update(deadbandVert, timestamp)

        _motionMetrics.value = BalloonMotionMetrics(
            rawHorizontalSpeedMS = rawHorizontal,
            rawVerticalSpeedMS = rawVertical,
            smoothedHorizontalSpeedMS = smoothHoriz,
            smoothedVerticalSpeedMS = smoothVert,
            adjustedDescentRateMS = _adjustedDescentRate.value ?: slowVert
        )
    }

    private fun updateAdjustedDescentRate(points: List<BalloonTrackPoint>) {
        val now = points.lastOrNull()?.timestamp ?: return
        val recent = points.filter { Duration.between(it.timestamp, now).seconds <= 60 }
        if (recent.size < 3) {
            return
        }

        val rates = mutableListOf<Double>()
        for (i in 1 until recent.size) {
            val prev = recent[i - 1]
            val curr = recent[i]
            val dt = Duration.between(prev.timestamp, curr.timestamp).seconds.toDouble().coerceAtLeast(1.0)
            rates.add((curr.altitude - prev.altitude) / dt)
        }

        val median = rates.sorted()[rates.size / 2]
        if (descentRateHistory.size >= 20) descentRateHistory.removeFirst()
        descentRateHistory.addLast(median)
        val avg = descentRateHistory.average()
        _adjustedDescentRate.value = avg
    }

    private fun detectTrackBasedLanding(points: List<BalloonTrackPoint>) {
        if (_trackBasedLandingDetected.value) return
        if (points.size < 10) return
        val burstIndex = points.indices.maxByOrNull { points[it].altitude } ?: return
        if (burstIndex >= points.size - 1) return

        val windowPoints = points.drop(burstIndex)
        val avgInterval = averageIntervalSeconds(points)
        val windowSize = max(10, (20 * 60 / max(1.0, avgInterval)).toInt())

        for (i in 1 until windowPoints.size) {
            val prev = windowPoints[i - 1]
            val curr = windowPoints[i]
            val gapMinutes = Duration.between(prev.timestamp, curr.timestamp).toMinutes()
            if (gapMinutes >= 20) {
                val landingPoint = prev
                truncateTrackAt(landingPoint)
                notificationSink?.notifyTrackTruncation("Telemetry gap after burst")
                return
            }
        }

        if (windowPoints.size >= windowSize) {
            val window = windowPoints.takeLast(windowSize)
            val latRange = window.maxOf { it.latitude } - window.minOf { it.latitude }
            val lonRange = window.maxOf { it.longitude } - window.minOf { it.longitude }
            val altRange = window.maxOf { it.altitude } - window.minOf { it.altitude }
            if (latRange < 0.0001 && lonRange < 0.0001 && altRange < 0.3) {
                val landingPoint = window.last()
                truncateTrackAt(landingPoint)
                notificationSink?.notifyTrackTruncation("Stationary after burst")
            }
        }
    }

    private fun truncateTrackAt(point: BalloonTrackPoint) {
        val truncated = _track.value.takeWhile { it.timestamp <= point.timestamp }
        _track.value = truncated
        _trackBasedLandingDetected.value = true
    }

    private fun averageIntervalSeconds(points: List<BalloonTrackPoint>): Double {
        if (points.size < 2) return 1.0
        var total = 0.0
        for (i in 1 until points.size) {
            total += Duration.between(points[i - 1].timestamp, points[i].timestamp).seconds
        }
        return total / (points.size - 1).toDouble().coerceAtLeast(1.0)
    }

    /**
     * Filter out points that would require impossible speeds.
     * Balloon max realistic speed: ~100 m/s horizontal (extreme jet stream).
     * Vertical: 50 m/s below 10km, 100 m/s above (post-burst free-fall can be extreme).
     *
     * Debug: Use logcat filter "TrackFilter" to see rejected points.
     */
    private fun filterImpossibleJumps(points: List<BalloonTrackPoint>): List<BalloonTrackPoint> {
        if (points.size < 2) return points

        val maxHorizontalSpeed = 100.0 // m/s (~360 km/h - extreme but possible in jet stream)

        val result = mutableListOf(points.first())
        var rejectedCount = 0

        for (i in 1 until points.size) {
            val prev = result.last()
            val curr = points[i]

            val dt = Duration.between(prev.timestamp, curr.timestamp).seconds.toDouble().coerceAtLeast(1.0)
            val distance = GeoUtils.haversineMeters(prev.point, curr.point)
            val horizontalSpeed = distance / dt
            val verticalSpeed = abs(curr.altitude - prev.altitude) / dt

            // At high altitude (>10km), allow faster vertical speeds (post-burst free-fall)
            val maxAlt = max(prev.altitude, curr.altitude)
            val maxVerticalSpeed = if (maxAlt > 10000) 100.0 else 50.0

            if (horizontalSpeed <= maxHorizontalSpeed && verticalSpeed <= maxVerticalSpeed) {
                result.add(curr)
            } else {
                rejectedCount++
                Log.w(TAG_FILTER, "REJECTED point #$i: " +
                    "from(${prev.latitude},${prev.longitude},alt=${prev.altitude.toInt()}m) " +
                    "to(${curr.latitude},${curr.longitude},alt=${curr.altitude.toInt()}m) " +
                    "dist=${distance.toInt()}m dt=${dt.toInt()}s " +
                    "hSpeed=${horizontalSpeed.toInt()}m/s vSpeed=${verticalSpeed.toInt()}m/s " +
                    "time=${curr.timestamp}")
            }
        }

        if (rejectedCount > 0) {
            Log.w(TAG_FILTER, "SUMMARY: Rejected $rejectedCount of ${points.size} points, kept ${result.size}")
        }

        return result
    }
}

class HampelFilter(private val window: Int, private val k: Double) {
    private val values = ArrayDeque<Double>()

    fun filter(value: Double): Double {
        if (values.size >= window) values.removeFirst()
        values.addLast(value)
        val list = values.toList()
        val median = list.sorted()[list.size / 2]
        val mad = list.map { abs(it - median) }.sorted()[list.size / 2]
        val threshold = k * 1.4826 * mad
        return if (mad == 0.0 || abs(value - median) <= threshold) value else median
    }
}

class EmaFilter(private val tauSeconds: Double) {
    private var lastValue: Double? = null
    private var lastTimestamp: Instant? = null

    fun update(value: Double, timestamp: Instant): Double {
        val prev = lastValue
        val prevTime = lastTimestamp
        val output = if (prev == null || prevTime == null) {
            value
        } else {
            val dt = Duration.between(prevTime, timestamp).seconds.toDouble().coerceAtLeast(1.0)
            val alpha = 1 - kotlin.math.exp(-dt / tauSeconds)
            prev + alpha * (value - prev)
        }
        lastValue = output
        lastTimestamp = timestamp
        return output
    }
}

interface TrackNotificationSink {
    fun notifyTrackTruncation(reason: String)
}
