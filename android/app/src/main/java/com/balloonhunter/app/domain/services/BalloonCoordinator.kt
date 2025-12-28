package com.balloonhunter.app.domain.services

import com.balloonhunter.app.data.LocationService
import com.balloonhunter.app.data.aprs.AprsService
import com.balloonhunter.app.data.ble.BleService
import com.balloonhunter.app.data.notifications.NotificationHelper
import com.balloonhunter.app.data.prediction.PredictionService
import com.balloonhunter.app.data.routing.RoutingService
import com.balloonhunter.app.data.persistence.LandingHistoryRepository
import com.balloonhunter.app.data.persistence.TelemetryLogger
import com.balloonhunter.app.data.persistence.TrackRepository
import com.balloonhunter.app.data.persistence.UserSettingsStore
import com.balloonhunter.app.domain.models.BalloonPhase
import com.balloonhunter.app.domain.models.DataState
import com.balloonhunter.app.domain.models.LandingPredictionSource
import com.balloonhunter.app.domain.models.PositionData
import com.balloonhunter.app.domain.models.TelemetrySource
import com.balloonhunter.app.domain.models.TransportationMode
import com.balloonhunter.app.domain.models.RouteData
import com.balloonhunter.app.domain.services.GeoUtils
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import java.time.Instant

class BalloonCoordinator(
    private val scope: CoroutineScope,
    private val bleService: BleService,
    private val aprsService: AprsService,
    private val trackRepository: TrackRepository,
    private val landingHistoryRepository: LandingHistoryRepository,
    private val settingsStore: UserSettingsStore,
    private val locationService: LocationService,
    private val routingService: RoutingService,
    private val notificationSink: TrackNotificationSink? = null,
    private val telemetryLogger: TelemetryLogger? = null
) : LandingPointListener {
    private val positionService = BalloonPositionService()
    private val trackService = BalloonTrackService(trackRepository, notificationSink)
    private val landingService = LandingPointService(landingHistoryRepository, this)
    private val predictionService = PredictionService(scope)

    private var startupJob: Job? = null
    private var waitingTimeoutJob: Job? = null

    private var latestBle: PositionData? = null
    private var latestAprs: PositionData? = null
    private var lastRouteOrigin: com.balloonhunter.app.domain.models.GeoPoint? = null
    private var lastRouteUpdate: Instant? = null

    val dataState = positionService.dataState
    val currentPosition = positionService.currentPosition
    val balloonPhase = positionService.balloonPhase
    val track = trackService.track
    val prediction = predictionService.prediction
    val landingHistory = landingService.history
    val currentLanding = landingService.currentLanding
    val userSettings = settingsStore.settings
    private val _route = kotlinx.coroutines.flow.MutableStateFlow<RouteData?>(null)
    val route: kotlinx.coroutines.flow.StateFlow<RouteData?> = _route

    fun start() {
        scope.launch(Dispatchers.Default) {
            val persistedTrack = trackRepository.loadTrack()
            val persistedLanding = landingHistoryRepository.loadLandingHistory()
            trackService.loadPersisted(persistedTrack)
            landingService.loadPersisted(persistedLanding)
        }

        locationService.requestCurrentLocation()
        bleService.start()
        aprsService.startPolling()

        startupJob?.cancel()
        startupJob = scope.launch(Dispatchers.Default) {
            delay(15000)
            positionService.setStartupComplete(true)
        }

        scope.launch {
            bleService.connectionState.collectLatest { state ->
                positionService.setBleConnectionState(state)
                positionService.setBleTelemetryAvailable(state == com.balloonhunter.app.domain.models.BLEConnectionState.DATA_READY)
            }
        }

        scope.launch {
            bleService.positionUpdates.collectLatest { position ->
                latestBle = position
                positionService.updatePosition(selectPosition())
                updatePhaseAndTrack(position)
            }
        }

        scope.launch {
            aprsService.positionUpdates.collectLatest { position ->
                latestAprs = position
                positionService.updatePosition(selectPosition())
                updatePhaseAndTrack(position)
            }
        }

        scope.launch {
            aprsService.aprsDataAvailable.collectLatest { available ->
                positionService.setAprsDataAvailable(available)
            }
        }

        scope.launch {
            positionService.dataState.collectLatest { state ->
                handleStateChange(state)
            }
        }

        scope.launch {
            predictionService.prediction.collectLatest { prediction ->
                val landing = prediction?.landingPoint ?: return@collectLatest
                landingService.updateLandingPoint(
                    landing,
                    prediction.landingTime,
                    LandingPredictionSource.SONDEHUB
                )
            }
        }

        scope.launch {
            trackService.trackBasedLandingDetected.collectLatest { detected ->
                if (detected) positionService.updateBalloonPhase(BalloonPhase.LANDED)
            }
        }

        scope.launch {
            settingsStore.settings.collectLatest { settings ->
                aprsService.setStationId(settings.stationId)
            }
        }

        scope.launch(Dispatchers.Default) {
            while (true) {
                bleService.downgradeIfType1Missing()
                delay(3000)
            }
        }

        scope.launch {
            locationService.location.collectLatest { location ->
                if (location == null) return@collectLatest
                val landing = currentLanding.value ?: return@collectLatest
                val lastOrigin = lastRouteOrigin
                val now = Instant.now()
                if (lastOrigin == null || lastRouteUpdate == null) return@collectLatest
                val distance = GeoUtils.haversineMeters(lastOrigin, location.point)
                val age = java.time.Duration.between(lastRouteUpdate, now).seconds
                if (distance > 100 && age > 60) {
                    val route = routingService.calculateRoute(location.point, landing.point, settingsStore.settings.value.transportMode)
                    _route.value = route
                    lastRouteOrigin = location.point
                    lastRouteUpdate = now
                }
            }
        }
    }

    fun stop() {
        bleService.stop()
        aprsService.stopPolling()
        predictionService.stopTimer()
        locationService.stopUpdates()
    }

    fun updateTransportMode(mode: TransportationMode) {
        scope.launch(Dispatchers.IO) {
            val current = settingsStore.settings.value
            settingsStore.update(current.copy(transportMode = mode))
        }
    }

    private fun selectPosition(): PositionData? {
        val bleActive = positionService.bleConnectionState.value == com.balloonhunter.app.domain.models.BLEConnectionState.DATA_READY
        return if (bleActive) latestBle ?: latestAprs else latestAprs ?: latestBle
    }

    private suspend fun updatePhaseAndTrack(position: PositionData) {
        val phase = BalloonPhaseDetector.determinePhase(
            positionService.currentPosition.value,
            trackService.track.value,
            trackService.trackBasedLandingDetected.value
        )
        positionService.updateBalloonPhase(phase)

        val state = positionService.dataState.value
        if (position.telemetrySource == TelemetrySource.BLE && state == DataState.WAITING_FOR_APRS) {
            // Ignore stale BLE in waiting state.
            return
        }
        trackService.recordPoint(position, state)
        telemetryLogger?.append(position, landingService.currentLanding.value)
    }

    private fun handleStateChange(state: DataState) {
        when (state) {
            DataState.STARTUP, DataState.NO_TELEMETRY -> {
                aprsService.startPolling()
                predictionService.stopTimer()
                locationService.startBackgroundUpdates()
            }
            DataState.LIVE_BLE_FLYING -> {
                aprsService.stopPolling()
                predictionService.startTimer(
                    positionProvider = { positionService.currentPosition.value },
                    settingsProvider = { settingsStore.settings.value },
                    phaseProvider = { positionService.balloonPhase.value },
                    adjustedDescentRateProvider = { trackService.adjustedDescentRate.value }
                )
                predictionServiceScopeTrigger()
            }
            DataState.LIVE_BLE_LANDED -> {
                aprsService.stopPolling()
                predictionService.stopTimer()
                positionService.currentPosition.value?.let { position ->
                    scope.launch { landingService.updateLandingPoint(position.point, null, LandingPredictionSource.MANUAL) }
                }
            }
            DataState.WAITING_FOR_APRS -> {
                aprsService.startPolling()
                startWaitingTimeout()
            }
            DataState.APRS_FLYING -> {
                aprsService.startPolling()
                predictionService.startTimer(
                    positionProvider = { positionService.currentPosition.value },
                    settingsProvider = { settingsStore.settings.value },
                    phaseProvider = { positionService.balloonPhase.value },
                    adjustedDescentRateProvider = { trackService.adjustedDescentRate.value }
                )
                predictionServiceScopeTrigger()
            }
            DataState.APRS_LANDED -> {
                aprsService.startPolling()
                predictionService.stopTimer()
                positionService.currentPosition.value?.let { position ->
                    scope.launch { landingService.updateLandingPoint(position.point, null, LandingPredictionSource.MANUAL) }
                }
            }
        }
    }

    private fun predictionServiceScopeTrigger() {
        scope.launch {
            val position = positionService.currentPosition.value ?: return@launch
            val settings = settingsStore.settings.value
            predictionService.requestPrediction(
                position,
                settings,
                positionService.balloonPhase.value,
                trackService.adjustedDescentRate.value
            )
            predictionService.prediction.value?.landingPoint?.let { landing ->
                landingService.updateLandingPoint(landing, predictionService.prediction.value?.landingTime, LandingPredictionSource.SONDEHUB)
            }
        }
    }

    private fun startWaitingTimeout() {
        waitingTimeoutJob?.cancel()
        waitingTimeoutJob = scope.launch(Dispatchers.Default) {
            delay(10000)
            if (positionService.dataState.value == DataState.WAITING_FOR_APRS && !aprsService.aprsDataAvailable.value) {
                positionService.setAprsDataAvailable(false)
                positionService.setBleTelemetryAvailable(false)
                positionService.forceNoTelemetry()
            }
        }
    }

    override fun onLandingPointChanged(point: com.balloonhunter.app.domain.models.LandingPredictionPoint) {
        scope.launch(Dispatchers.IO) {
            val location = locationService.location.value ?: return@launch
            val route = routingService.calculateRoute(location.point, point.point, settingsStore.settings.value.transportMode)
            _route.value = route
            lastRouteOrigin = location.point
            lastRouteUpdate = Instant.now()
        }
        (notificationSink as? NotificationHelper)?.notifyNavigationUpdate(point, settingsStore.settings.value.transportMode)
    }
}
