package com.balloonhunter.app.data.persistence

import androidx.room.Entity
import androidx.room.PrimaryKey
import java.time.Instant

@Entity(tableName = "track_points")
data class TrackPointEntity(
    @PrimaryKey val epochSeconds: Long,
    val latitude: Double,
    val longitude: Double,
    val altitude: Double,
    val verticalSpeed: Double,
    val horizontalSpeed: Double
) {
    fun toInstant(): Instant = Instant.ofEpochSecond(epochSeconds)
}

@Entity(tableName = "landing_points")
data class LandingPointEntity(
    @PrimaryKey val predictedAtEpochSeconds: Long,
    val latitude: Double,
    val longitude: Double,
    val landingEtaEpochSeconds: Long?,
    val source: String
)
