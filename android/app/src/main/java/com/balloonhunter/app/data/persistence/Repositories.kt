package com.balloonhunter.app.data.persistence

import com.balloonhunter.app.domain.models.BalloonTrackPoint
import com.balloonhunter.app.domain.models.LandingPredictionPoint
import com.balloonhunter.app.domain.models.LandingPredictionSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.Instant

class TrackRepository(private val dao: TrackPointDao) {
    suspend fun loadTrack(): List<BalloonTrackPoint> = withContext(Dispatchers.IO) {
        dao.getAll().map {
            BalloonTrackPoint(
                latitude = it.latitude,
                longitude = it.longitude,
                altitude = it.altitude,
                timestamp = Instant.ofEpochSecond(it.epochSeconds),
                verticalSpeed = it.verticalSpeed,
                horizontalSpeed = it.horizontalSpeed
            )
        }
    }

    suspend fun insert(point: BalloonTrackPoint) = withContext(Dispatchers.IO) {
        dao.insert(
            TrackPointEntity(
                epochSeconds = point.timestamp.epochSecond,
                latitude = point.latitude,
                longitude = point.longitude,
                altitude = point.altitude,
                verticalSpeed = point.verticalSpeed,
                horizontalSpeed = point.horizontalSpeed
            )
        )
    }

    suspend fun clear() = withContext(Dispatchers.IO) { dao.clear() }

    suspend fun replaceTrack(points: List<BalloonTrackPoint>) = withContext(Dispatchers.IO) {
        dao.clear()
        points.forEach { point ->
            dao.insert(
                TrackPointEntity(
                    epochSeconds = point.timestamp.epochSecond,
                    latitude = point.latitude,
                    longitude = point.longitude,
                    altitude = point.altitude,
                    verticalSpeed = point.verticalSpeed,
                    horizontalSpeed = point.horizontalSpeed
                )
            )
        }
    }
}

class LandingHistoryRepository(private val dao: LandingPointDao) {
    suspend fun loadLandingHistory(): List<LandingPredictionPoint> = withContext(Dispatchers.IO) {
        dao.getAll().map {
            LandingPredictionPoint(
                latitude = it.latitude,
                longitude = it.longitude,
                predictedAt = Instant.ofEpochSecond(it.predictedAtEpochSeconds),
                landingEta = it.landingEtaEpochSeconds?.let { eta -> Instant.ofEpochSecond(eta) },
                source = if (it.source == LandingPredictionSource.MANUAL.name) {
                    LandingPredictionSource.MANUAL
                } else {
                    LandingPredictionSource.SONDEHUB
                }
            )
        }
    }

    suspend fun insert(point: LandingPredictionPoint) = withContext(Dispatchers.IO) {
        dao.insert(
            LandingPointEntity(
                predictedAtEpochSeconds = point.predictedAt.epochSecond,
                latitude = point.latitude,
                longitude = point.longitude,
                landingEtaEpochSeconds = point.landingEta?.epochSecond,
                source = point.source.name
            )
        )
    }

    suspend fun clear() = withContext(Dispatchers.IO) { dao.clear() }
}
