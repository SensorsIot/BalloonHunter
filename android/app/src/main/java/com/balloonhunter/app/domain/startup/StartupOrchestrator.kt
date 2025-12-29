package com.balloonhunter.app.domain.startup

import com.balloonhunter.app.data.LocationService
import com.balloonhunter.app.data.aprs.AprsService
import com.balloonhunter.app.data.ble.BleService
import com.balloonhunter.app.data.persistence.LandingHistoryRepository
import com.balloonhunter.app.data.persistence.TrackRepository
import com.balloonhunter.app.domain.models.BalloonTrackPoint
import com.balloonhunter.app.domain.models.LandingPredictionPoint
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * StartupOrchestrator handles the application startup sequence.
 *
 * Responsibilities (per FSD):
 * - Start services in correct order
 * - Collect necessary telemetry, connection status, and decision inputs
 * - Establish BLE connections and initial APRS polling
 * - Provide decision points for state machine evaluation
 * - Exit criteria: When all decision info for state machine is ready
 * - NO business logic: Startup only prepares inputs
 */
class StartupOrchestrator(
    private val scope: CoroutineScope,
    private val bleService: BleService,
    private val aprsService: AprsService,
    private val locationService: LocationService,
    private val trackRepository: TrackRepository,
    private val landingHistoryRepository: LandingHistoryRepository
) {
    companion object {
        private const val STARTUP_TIMEOUT_MS = 15000L
    }

    private var startupJob: Job? = null

    private val _isStartupComplete = MutableStateFlow(false)
    val isStartupComplete: StateFlow<Boolean> = _isStartupComplete.asStateFlow()

    private val _persistedTrack = MutableStateFlow<List<BalloonTrackPoint>>(emptyList())
    val persistedTrack: StateFlow<List<BalloonTrackPoint>> = _persistedTrack.asStateFlow()

    private val _persistedLandingHistory = MutableStateFlow<List<LandingPredictionPoint>>(emptyList())
    val persistedLandingHistory: StateFlow<List<LandingPredictionPoint>> = _persistedLandingHistory.asStateFlow()

    /**
     * Execute the startup sequence:
     * 1. Load persisted data (track, landing history)
     * 2. Request current location
     * 3. Start BLE service
     * 4. Start APRS polling
     * 5. Start startup timeout timer
     *
     * @param onStartupComplete Callback when startup is complete (timeout or conditions met)
     */
    fun start(onStartupComplete: () -> Unit) {
        // Load persisted data in background
        scope.launch(Dispatchers.Default) {
            val track = trackRepository.loadTrack()
            val landingHistory = landingHistoryRepository.loadLandingHistory()
            _persistedTrack.value = track
            _persistedLandingHistory.value = landingHistory
        }

        // Request initial location
        locationService.requestCurrentLocation()

        // Start services
        bleService.start()
        aprsService.startPolling()

        // Start startup timeout
        startupJob?.cancel()
        startupJob = scope.launch(Dispatchers.Default) {
            delay(STARTUP_TIMEOUT_MS)
            _isStartupComplete.value = true
            onStartupComplete()
        }
    }

    /**
     * Mark startup as complete immediately (e.g., when telemetry is received before timeout).
     */
    fun completeStartup() {
        startupJob?.cancel()
        _isStartupComplete.value = true
    }

    /**
     * Cancel startup and cleanup.
     */
    fun cancel() {
        startupJob?.cancel()
        startupJob = null
    }
}
