package com.balloonhunter.app.domain.services

import com.balloonhunter.app.data.persistence.TrackRepository
import com.balloonhunter.app.domain.models.BalloonMotionMetrics
import com.balloonhunter.app.domain.models.BalloonTrackPoint
import com.balloonhunter.app.domain.models.DataState
import com.balloonhunter.app.domain.models.PositionData
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.time.Duration
import java.time.Instant
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

class BalloonTrackService(
    private val trackRepository: TrackRepository,
    private val notificationSink: TrackNotificationSink? = null
) {
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

    suspend fun loadPersisted(points: List<BalloonTrackPoint>) {
        _track.value = points
    }

    suspend fun recordPoint(position: PositionData, state: DataState) {
        if (state == DataState.STARTUP || state == DataState.WAITING_FOR_APRS ||
            state == DataState.NO_TELEMETRY || state == DataState.APRS_LANDED
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

        val updated = existing + point
        _track.value = updated
        trackRepository.insert(point)

        updateMotionMetrics(horizontalSpeed, verticalSpeed, timestamp)
        updateAdjustedDescentRate(updated)
        detectTrackBasedLanding(updated)
    }

    fun insertGapFill(points: List<BalloonTrackPoint>) {
        if (points.isEmpty()) return
        val current = _track.value.associateBy { it.timestamp.epochSecond }.toMutableMap()
        for (point in points) {
            current.putIfAbsent(point.timestamp.epochSecond, point)
        }
        _track.value = current.values.sortedBy { it.timestamp }
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

    private suspend fun detectTrackBasedLanding(points: List<BalloonTrackPoint>) {
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

    private suspend fun truncateTrackAt(point: BalloonTrackPoint) {
        val truncated = _track.value.takeWhile { it.timestamp <= point.timestamp }
        _track.value = truncated
        _trackBasedLandingDetected.value = true
        trackRepository.replaceTrack(truncated)
    }

    private fun averageIntervalSeconds(points: List<BalloonTrackPoint>): Double {
        if (points.size < 2) return 1.0
        var total = 0.0
        for (i in 1 until points.size) {
            total += Duration.between(points[i - 1].timestamp, points[i].timestamp).seconds
        }
        return total / (points.size - 1).toDouble().coerceAtLeast(1.0)
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
