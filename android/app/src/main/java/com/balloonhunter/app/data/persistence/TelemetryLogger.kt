package com.balloonhunter.app.data.persistence

import android.content.Context
import com.balloonhunter.app.domain.models.LandingPredictionPoint
import com.balloonhunter.app.domain.models.PositionData
import java.io.File
import java.time.format.DateTimeFormatter

class TelemetryLogger(private val context: Context) {
    private val file: File by lazy {
        val dir = context.getExternalFilesDir(null) ?: context.filesDir
        File(dir, "telemetry_log.csv")
    }

    fun append(position: PositionData, landingPoint: LandingPredictionPoint?) {
        if (position.sondeName.startsWith("DEV", ignoreCase = true)) return
        val header = "timestamp,sondeName,latitude,longitude,altitude,landingLat,landingLon"
        if (!file.exists()) {
            file.writeText(header + "\n")
        }
        val timestamp = DateTimeFormatter.ISO_INSTANT.format(position.timestamp)
        val landingLat = landingPoint?.latitude?.toString() ?: ""
        val landingLon = landingPoint?.longitude?.toString() ?: ""
        val line = listOf(
            timestamp,
            position.sondeName,
            position.latitude.toString(),
            position.longitude.toString(),
            position.altitude.toString(),
            landingLat,
            landingLon
        ).joinToString(",")
        file.appendText(line + "\n")
    }
}
