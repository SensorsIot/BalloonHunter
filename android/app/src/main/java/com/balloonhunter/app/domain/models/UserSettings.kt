package com.balloonhunter.app.domain.models

enum class NavigationProvider {
    GOOGLE_MAPS,
    OSM
}

enum class MapProvider {
    GOOGLE_MAPS,
    OSM
}

data class UserSettings(
    val burstAltitude: Double,
    val ascentRate: Double,
    val descentRate: Double,
    val stationId: String,
    val navigationProvider: NavigationProvider = NavigationProvider.OSM,
    val mapProvider: MapProvider = MapProvider.OSM
    // transportMode is ephemeral - managed in MapViewModel, not persisted
)
