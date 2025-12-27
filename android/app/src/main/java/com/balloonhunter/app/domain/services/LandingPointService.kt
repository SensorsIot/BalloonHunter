package com.balloonhunter.app.domain.services

import com.balloonhunter.app.data.persistence.LandingHistoryRepository
import com.balloonhunter.app.domain.models.GeoPoint
import com.balloonhunter.app.domain.models.LandingPredictionPoint
import com.balloonhunter.app.domain.models.LandingPredictionSource
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.time.Instant

class LandingPointService(
    private val repository: LandingHistoryRepository,
    private val listener: LandingPointListener? = null
) {
    private val _currentLanding = MutableStateFlow<LandingPredictionPoint?>(null)
    val currentLanding: StateFlow<LandingPredictionPoint?> = _currentLanding.asStateFlow()

    private val _history = MutableStateFlow<List<LandingPredictionPoint>>(emptyList())
    val history: StateFlow<List<LandingPredictionPoint>> = _history.asStateFlow()

    suspend fun loadPersisted(points: List<LandingPredictionPoint>) {
        _history.value = points
    }

    suspend fun updateLandingPoint(
        point: GeoPoint,
        landingEta: Instant?,
        source: LandingPredictionSource
    ) {
        val current = _currentLanding.value
        if (current != null) {
            val distance = GeoUtils.haversineMeters(current.point, point)
            if (distance < 25) {
                return
            }
        }
        val newPoint = LandingPredictionPoint(
            latitude = point.latitude,
            longitude = point.longitude,
            predictedAt = Instant.now(),
            landingEta = landingEta,
            source = source
        )
        _currentLanding.value = newPoint
        listener?.onLandingPointChanged(newPoint)
        if (source == LandingPredictionSource.SONDEHUB) {
            val updated = _history.value + newPoint
            _history.value = updated
            repository.insert(newPoint)
        }
    }
}

interface LandingPointListener {
    fun onLandingPointChanged(point: LandingPredictionPoint)
}
