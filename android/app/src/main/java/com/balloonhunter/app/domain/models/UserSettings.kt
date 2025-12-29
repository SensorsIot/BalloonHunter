package com.balloonhunter.app.domain.models

enum class NavigationProvider {
    GOOGLE_MAPS,
    OSMAND,
    ORGANIC_MAPS
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
    val navigationProvider: NavigationProvider = NavigationProvider.OSMAND,
    val mapProvider: MapProvider = MapProvider.OSM
    // transportMode is ephemeral - managed in MapViewModel, not persisted
)
