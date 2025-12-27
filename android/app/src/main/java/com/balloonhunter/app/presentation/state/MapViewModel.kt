package com.balloonhunter.app.presentation.state

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.balloonhunter.app.domain.models.DataState
import com.balloonhunter.app.domain.models.TransportationMode
import com.balloonhunter.app.domain.services.BalloonCoordinator
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import com.balloonhunter.app.domain.models.GeoPoint
import javax.inject.Inject

@HiltViewModel
class MapViewModel @Inject constructor(
    private val coordinator: BalloonCoordinator
) : ViewModel() {
    val dataState = coordinator.dataState
    val position = coordinator.currentPosition
    val balloonPhase = coordinator.balloonPhase
    val track = coordinator.track
    val prediction = coordinator.prediction
    val landingHistory = coordinator.landingHistory
    val currentLanding = coordinator.currentLanding
    val userSettings = coordinator.userSettings
    val route = coordinator.route

    private val _headingMode = MutableStateFlow(false)
    val headingMode: StateFlow<Boolean> = _headingMode.asStateFlow()

    private val _satelliteMode = MutableStateFlow(false)
    val satelliteMode: StateFlow<Boolean> = _satelliteMode.asStateFlow()

    private val _showAll = MutableStateFlow(false)
    val showAll: StateFlow<Boolean> = _showAll.asStateFlow()

    private val _transportMode = MutableStateFlow(TransportationMode.CAR)
    val transportMode: StateFlow<TransportationMode> = _transportMode.asStateFlow()

    init {
        coordinator.start()
        viewModelScope.launch {
            userSettings.collect { settings ->
                _transportMode.value = settings.transportMode
            }
        }
    }

    override fun onCleared() {
        coordinator.stop()
        super.onCleared()
    }

    fun toggleHeading() {
        _headingMode.value = !_headingMode.value
    }

    fun toggleSatellite() {
        _satelliteMode.value = !_satelliteMode.value
    }

    fun toggleShowAll() {
        _showAll.value = !_showAll.value
    }

    fun setTransportMode(mode: TransportationMode) {
        _transportMode.value = mode
        coordinator.updateTransportMode(mode)
    }

    fun updateLandingPoint(point: GeoPoint) = Unit
}
