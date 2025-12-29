package com.balloonhunter.app.presentation.state

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.balloonhunter.app.data.CompassService
import com.balloonhunter.app.domain.models.CameraUpdate
import com.balloonhunter.app.domain.models.DataState
import com.balloonhunter.app.domain.models.GeoPoint
import com.balloonhunter.app.domain.models.MapAnnotationItem
import com.balloonhunter.app.domain.models.TransportationMode
import com.balloonhunter.app.domain.services.BalloonCoordinator
import com.balloonhunter.app.domain.services.GeoUtils
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class MapViewModel @Inject constructor(
    private val coordinator: BalloonCoordinator,
    private val compassService: CompassService
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
    val userLocation = coordinator.userLocation

    // Route visibility: hide if user is within 100m of balloon
    val routeVisible: StateFlow<Boolean> = combine(userLocation, position) { location, balloonPos ->
        if (location == null || balloonPos == null) return@combine true
        val distance = GeoUtils.haversineMeters(location.point, balloonPos.point)
        distance > 100.0
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), true)

    private val _headingMode = MutableStateFlow(false)
    val headingMode: StateFlow<Boolean> = _headingMode.asStateFlow()

    // Compass heading from device sensors (0-360 degrees from north)
    val compassHeading: StateFlow<Float> = compassService.heading

    private val _satelliteMode = MutableStateFlow(false)
    val satelliteMode: StateFlow<Boolean> = _satelliteMode.asStateFlow()

    private val _showAll = MutableStateFlow(false)
    val showAll: StateFlow<Boolean> = _showAll.asStateFlow()

    // Startup fit-all: triggers once when data becomes available
    private var hasPerformedStartupFit = false

    init {
        // Watch for data to trigger startup fit-all
        viewModelScope.launch {
            combine(track, position, userLocation) { trackPoints, pos, userLoc ->
                Triple(trackPoints, pos, userLoc)
            }.collect { (trackPoints, pos, userLoc) ->
                // Trigger fit-all once we have any data (track, position, or user location)
                if (!hasPerformedStartupFit && (trackPoints.isNotEmpty() || pos != null || userLoc != null)) {
                    hasPerformedStartupFit = true
                    // Small delay to ensure map is ready
                    kotlinx.coroutines.delay(500)
                    requestFitAll()
                }
            }
        }
    }

    // Transport mode is ephemeral - exposed from coordinator
    val transportMode = coordinator.transportMode

    // Map annotations - single source of truth for all map overlays
    // Combines all data sources and applies visibility logic
    val annotations: StateFlow<List<MapAnnotationItem>> = combine(
        combine(position, balloonPhase, track) { pos, phase, trackPoints ->
            Triple(pos, phase, trackPoints)
        },
        combine(prediction, currentLanding, landingHistory) { pred, landing, history ->
            Triple(pred, landing, history)
        },
        combine(route, routeVisible) { routeData, visible ->
            Pair(routeData, visible)
        }
    ) { (pos, phase, trackPoints), (pred, landing, history), (routeData, routeIsVisible) ->
        buildList {
            // Track polyline
            if (trackPoints.isNotEmpty()) {
                add(MapAnnotationItem.TrackPolyline(trackPoints.map { it.point }))
            }

            // Prediction path polyline
            pred?.path?.let { path ->
                if (path.isNotEmpty()) {
                    add(MapAnnotationItem.PredictionPolyline(path))
                }
            }

            // Burst marker - only visible while ascending
            if (phase == com.balloonhunter.app.domain.models.BalloonPhase.ASCENDING) {
                pred?.burstPoint?.let { burst ->
                    add(MapAnnotationItem.BurstMarker(burst))
                }
            }

            // Route polyline - hidden if user within 100m of balloon
            if (routeIsVisible) {
                routeData?.let { r ->
                    if (r.coordinates.isNotEmpty()) {
                        add(MapAnnotationItem.RoutePolyline(r.coordinates))
                    }
                }
            }

            // Landing history polyline and dots
            if (history.size >= 2) {
                add(MapAnnotationItem.LandingHistoryPolyline(history.map { it.point }))
            }
            history.forEach { historyPoint ->
                add(MapAnnotationItem.LandingHistoryDot(historyPoint.point))
            }

            // Landing marker
            landing?.let { l ->
                add(MapAnnotationItem.LandingMarker(l.point))
            }

            // Balloon marker
            pos?.let { p ->
                add(MapAnnotationItem.BalloonMarker(
                    position = p.point,
                    title = p.sondeName.ifBlank { "Balloon" },
                    phase = phase
                ))
            }
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    // Camera update requests - consumed once by the view
    private val _cameraUpdate = MutableStateFlow<CameraUpdate?>(null)
    val cameraUpdate: StateFlow<CameraUpdate?> = _cameraUpdate.asStateFlow()

    init {
        coordinator.start()
    }

    override fun onCleared() {
        compassService.stopListening()
        coordinator.stop()
        super.onCleared()
    }

    fun toggleHeading() {
        _headingMode.value = !_headingMode.value
        if (_headingMode.value) {
            compassService.startListening()
        } else {
            compassService.stopListening()
        }
    }

    fun toggleSatellite() {
        _satelliteMode.value = !_satelliteMode.value
    }

    fun toggleShowAll() {
        _showAll.value = !_showAll.value
    }

    /**
     * Request camera to fit all annotations in view.
     * Collects all points from track, prediction, landing, and balloon position.
     */
    fun requestFitAll() {
        val allPoints = mutableListOf<GeoPoint>()

        // Include track points
        track.value.forEach { allPoints.add(it.point) }
        // Include prediction path
        prediction.value?.path?.let { allPoints.addAll(it) }
        // Include landing point
        currentLanding.value?.let { allPoints.add(it.point) }
        // Include balloon position
        position.value?.let { allPoints.add(it.point) }
        // Include user location
        userLocation.value?.let { allPoints.add(it.point) }

        if (allPoints.isNotEmpty()) {
            _cameraUpdate.value = CameraUpdate.FitBounds(allPoints, padding = 150)
        }
    }

    /**
     * Clear the camera update after it has been consumed by the view.
     */
    fun consumeCameraUpdate() {
        _cameraUpdate.value = null
    }

    fun setTransportMode(mode: TransportationMode) {
        coordinator.updateTransportMode(mode)
    }

    fun resetBle() {
        coordinator.resetBle()
    }

    fun updateSettings(settings: com.balloonhunter.app.domain.models.UserSettings) {
        coordinator.updateSettings(settings)
    }

    // Device settings
    val deviceSettings = coordinator.deviceSettings
    val bleConnectionState = coordinator.bleConnectionState
    val radioData = coordinator.radioData
    val afcData = coordinator.afcData

    fun requestDeviceSettings() = coordinator.requestDeviceSettings()
    fun setMute(muted: Boolean) = coordinator.setMute(muted)
    fun setOLEDPins(sda: Int, scl: Int, rst: Int) = coordinator.setOLEDPins(sda, scl, rst)
    fun setLEDPin(pin: Int) = coordinator.setLEDPin(pin)
    fun setBuzzerPin(pin: Int) = coordinator.setBuzzerPin(pin)
    fun setBatterySettings(pin: Int, minVoltage: Int, maxVoltage: Int, dischargeType: Int) =
        coordinator.setBatterySettings(pin, minVoltage, maxVoltage, dischargeType)
    fun setCallSign(callSign: String) = coordinator.setCallSign(callSign)
    fun setRXBandwidth(rs41: Int?, m20: Int?, m10: Int?, pilot: Int?, dfm: Int?) =
        coordinator.setRXBandwidth(rs41, m20, m10, pilot, dfm)
    fun setLCDDriver(type: Int) = coordinator.setLCDDriver(type)
    fun setLCDOn(enabled: Boolean) = coordinator.setLCDOn(enabled)
    fun setBluetoothEnabled(enabled: Boolean) = coordinator.setBluetoothEnabled(enabled)
    fun setNameType(type: Int) = coordinator.setNameType(type)
    fun setFrequency(frequency: Double, probeType: String) = coordinator.setFrequency(frequency, probeType)
    fun setFrequencyCorrection(correction: Int) = coordinator.setFrequencyCorrection(correction)

    fun updateLandingPoint(point: GeoPoint) = Unit

    // Frequency mismatch detection
    val frequencyMismatch = coordinator.frequencyMismatch
    fun acceptFrequencyMismatch() = coordinator.acceptFrequencyMismatch()
    fun dismissFrequencyMismatch() = coordinator.dismissFrequencyMismatch()
}
