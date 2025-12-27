package com.balloonhunter.app.domain.models

import java.time.Instant

enum class TransportationMode { CAR, BIKE }

enum class BalloonPhase { ASCENDING, DESCENDING_ABOVE_10K, DESCENDING_BELOW_10K, LANDED, UNKNOWN }

enum class TelemetrySource { BLE, APRS }

enum class BLEConnectionState { NOT_CONNECTED, READY_FOR_COMMANDS, DATA_READY }

enum class DataState {
    STARTUP,
    LIVE_BLE_FLYING,
    LIVE_BLE_LANDED,
    WAITING_FOR_APRS,
    APRS_FLYING,
    APRS_LANDED,
    NO_TELEMETRY
}

enum class LandingPredictionSource { SONDEHUB, MANUAL }

data class GeoPoint(val latitude: Double, val longitude: Double)

fun GeoPoint.isValid(): Boolean {
    return latitude.isFinite() && longitude.isFinite() &&
        kotlin.math.abs(latitude) <= 90.0 && kotlin.math.abs(longitude) <= 180.0 &&
        !(latitude == 0.0 && longitude == 0.0)
}

data class PositionData(
    val sondeName: String,
    val latitude: Double,
    val longitude: Double,
    val altitude: Double,
    val verticalSpeed: Double,
    val horizontalSpeed: Double,
    val heading: Double,
    val temperature: Double,
    val humidity: Double,
    val pressure: Double,
    val timestamp: Instant,
    val apiCallTimestamp: Instant?,
    val burstKillerTime: Int,
    val telemetrySource: TelemetrySource
) {
    val point: GeoPoint = GeoPoint(latitude, longitude)
}

data class RadioChannelData(
    val sondeName: String,
    val timestamp: Instant,
    val telemetrySource: TelemetrySource,
    val probeType: String,
    val frequency: Double,
    val softwareVersion: String,
    val batteryVoltage: Double,
    val batteryPercentage: Int,
    val signalStrength: Int,
    val buzmute: Boolean,
    val afcFrequency: Int,
    val burstKillerEnabled: Boolean,
    val burstKillerTime: Int
)

data class SettingsData(
    val sondeName: String,
    val timestamp: Instant,
    val telemetrySource: TelemetrySource,
    val oledSDA: Int,
    val oledSCL: Int,
    val oledRST: Int,
    val ledPin: Int,
    val RS41Bandwidth: Int,
    val M20Bandwidth: Int,
    val M10Bandwidth: Int,
    val PILOTBandwidth: Int,
    val DFMBandwidth: Int,
    val frequencyCorrection: Int,
    val batPin: Int,
    val batMin: Int,
    val batMax: Int,
    val batType: Int,
    val lcdType: Int,
    val nameType: Int,
    val buzPin: Int,
    val callSign: String,
    val bluetoothStatus: Int,
    val lcdStatus: Int,
    val serialSpeed: Int,
    val serialPort: Int,
    val aprsName: Int
)

data class LocationData(
    val latitude: Double,
    val longitude: Double,
    val altitude: Double,
    val horizontalAccuracy: Double,
    val verticalAccuracy: Double,
    val heading: Double,
    val timestamp: Instant
) {
    val point: GeoPoint = GeoPoint(latitude, longitude)
}

data class BalloonTrackPoint(
    val latitude: Double,
    val longitude: Double,
    val altitude: Double,
    val timestamp: Instant,
    val verticalSpeed: Double,
    val horizontalSpeed: Double
) {
    val point: GeoPoint = GeoPoint(latitude, longitude)
}

data class BalloonMotionMetrics(
    val rawHorizontalSpeedMS: Double,
    val rawVerticalSpeedMS: Double,
    val smoothedHorizontalSpeedMS: Double,
    val smoothedVerticalSpeedMS: Double,
    val adjustedDescentRateMS: Double?
)

data class PredictionData(
    val path: List<GeoPoint>?,
    val burstPoint: GeoPoint?,
    val landingPoint: GeoPoint?,
    val landingTime: Instant?,
    val launchPoint: GeoPoint?,
    val burstAltitude: Double?,
    val flightTime: Double?,
    val metadata: Map<String, Any>?,
    val usedSmoothedDescentRate: Boolean
)

data class LandingPredictionPoint(
    val latitude: Double,
    val longitude: Double,
    val predictedAt: Instant,
    val landingEta: Instant?,
    val source: LandingPredictionSource
) {
    val point: GeoPoint = GeoPoint(latitude, longitude)
}

data class RouteData(
    val coordinates: List<GeoPoint>,
    val distance: Double,
    val expectedTravelTime: Double,
    val transportType: TransportationMode
)
