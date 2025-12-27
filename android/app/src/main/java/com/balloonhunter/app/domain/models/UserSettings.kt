package com.balloonhunter.app.domain.models

data class UserSettings(
    val burstAltitude: Double,
    val ascentRate: Double,
    val descentRate: Double,
    val stationId: String,
    val transportMode: TransportationMode
)
