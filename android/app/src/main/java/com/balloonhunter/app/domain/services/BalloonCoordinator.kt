package com.balloonhunter.app.domain.services

import android.util.Log
import com.balloonhunter.app.data.LocationService
import com.balloonhunter.app.data.aprs.AprsService
import com.balloonhunter.app.data.ble.BleService
import com.balloonhunter.app.data.notifications.NotificationHelper
import com.balloonhunter.app.data.prediction.PredictionService
import com.balloonhunter.app.data.routing.RoutingService
import com.balloonhunter.app.data.persistence.TelemetryLogger
import com.balloonhunter.app.data.persistence.UserSettingsStore
import com.balloonhunter.app.domain.startup.StartupOrchestrator
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
    private val settingsStore: UserSettingsStore,
    private val locationService: LocationService,
    private val routingService: RoutingService,
    private val notificationSink: TrackNotificationSink? = null,
    private val telemetryLogger: TelemetryLogger? = null,
    private val positionService: BalloonPositionService,
    private val trackService: BalloonTrackService,
    private val landingService: LandingPointService,
    private val predictionService: PredictionService,
    private val startupOrchestrator: StartupOrchestrator
) : LandingPointListener {

    init {
        // Register this coordinator as listener/sink for injected services
        landingService.setListener(this)
        notificationSink?.let { trackService.setNotificationSink(it) }
    }

    private var waitingTimeoutJob: Job? = null

    private var latestBle: PositionData? = null
    private var latestAprs: PositionData? = null

    // Background policy: when true, only BLE is active
    private var isInBackground = false
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
    val deviceSettings = bleService.settingsUpdates
    val bleConnectionState = bleService.connectionState
    val radioData = bleService.radioUpdates
    val afcData = bleService.afcUpdates
    val userLocation = locationService.location
    private val _route = kotlinx.coroutines.flow.MutableStateFlow<RouteData?>(null)
    val route: kotlinx.coroutines.flow.StateFlow<RouteData?> = _route

    // Ephemeral transport mode - not persisted
    private val _transportMode = kotlinx.coroutines.flow.MutableStateFlow(TransportationMode.CAR)
    val transportMode: kotlinx.coroutines.flow.StateFlow<TransportationMode> = _transportMode

    // Frequency mismatch detection
    data class FrequencyMismatch(
        val bleFrequency: Double,
        val bleProbeType: String,
        val aprsFrequency: Double,
        val aprsProbeType: String
    )
    private val _frequencyMismatch = kotlinx.coroutines.flow.MutableStateFlow<FrequencyMismatch?>(null)
    val frequencyMismatch: kotlinx.coroutines.flow.StateFlow<FrequencyMismatch?> = _frequencyMismatch
    private var mismatchDeferredUntil: Instant? = null

    // Track current sonde name for change detection (like iOS currentBalloonName)
    private var currentSondeName: String? = null

    fun start() {
        // Use StartupOrchestrator for startup sequence
        startupOrchestrator.start {
            positionService.setStartupComplete(true)
        }

        // Watch for persisted landing history from orchestrator
        // Note: Track is NOT persisted - it's fetched from SondeHub API on sonde change
        scope.launch {
            startupOrchestrator.persistedLandingHistory.collectLatest { history ->
                if (history.isNotEmpty()) {
                    landingService.loadPersisted(history)
                }
            }
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
                // Detect sonde change from BLE (like iOS)
                handleSondeChange(position.sondeName)
                positionService.updatePosition(selectPosition())
                updatePhaseAndTrack(position)
            }
        }

        scope.launch {
            aprsService.positionUpdates.collectLatest { position ->
                latestAprs = position
                // Detect sonde change from APRS (like iOS)
                handleSondeChange(position.sondeName)
                positionService.updatePosition(selectPosition())
                updatePhaseAndTrack(position)
                checkFrequencyMismatch()
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
                    val route = routingService.calculateRoute(location.point, landing.point, _transportMode.value, settingsStore.settings.value.mapProvider)
                    _route.value = route
                    lastRouteOrigin = location.point
                    lastRouteUpdate = now
                }
            }
        }
    }

    fun stop() {
        startupOrchestrator.cancel()
        bleService.stop()
        aprsService.stopPolling()
        predictionService.stopTimer()
        locationService.stopUpdates()
    }

    /**
     * Background policy: pause APRS, prediction, routing, location updates.
     * Only BLE remains active for receiving telemetry.
     */
    fun enterBackground() {
        if (isInBackground) return
        isInBackground = true
        aprsService.stopPolling()
        predictionService.stopTimer()
        locationService.stopUpdates()
    }

    /**
     * Resume all services when app returns to foreground.
     */
    fun enterForeground() {
        if (!isInBackground) return
        isInBackground = false

        // Re-evaluate state and start appropriate services
        when (dataState.value) {
            DataState.STARTUP, DataState.NO_TELEMETRY, DataState.WAITING_FOR_APRS,
            DataState.APRS_FLYING, DataState.APRS_LANDED -> {
                aprsService.startPolling()
            }
            else -> { /* BLE states - APRS stays off */ }
        }

        when (dataState.value) {
            DataState.LIVE_BLE_FLYING, DataState.APRS_FLYING -> {
                predictionService.startTimer(
                    positionProvider = { positionService.currentPosition.value },
                    settingsProvider = { settingsStore.settings.value },
                    phaseProvider = { positionService.balloonPhase.value },
                    adjustedDescentRateProvider = { trackService.adjustedDescentRate.value }
                )
            }
            else -> { /* Prediction not needed */ }
        }

        locationService.startBackgroundUpdates()
    }

    fun resetBle() {
        bleService.resetConnection()
    }

    /**
     * Enable precision location updates for heading/compass mode.
     * Uses more battery but provides more accurate and frequent updates.
     */
    fun enablePrecisionLocation() {
        locationService.startPrecisionUpdates()
    }

    /**
     * Disable precision location updates, return to background mode.
     */
    fun disablePrecisionLocation() {
        locationService.startBackgroundUpdates()
    }

    fun updateTransportMode(mode: TransportationMode) {
        _transportMode.value = mode
        // Recalculate route with new mode
        scope.launch(Dispatchers.IO) {
            val location = locationService.location.value
            val landing = currentLanding.value
            Log.d("BalloonCoordinator", "updateTransportMode: mode=$mode location=$location landing=$landing")
            if (location == null) {
                Log.w("BalloonCoordinator", "updateTransportMode: no user location, cannot calculate route")
                return@launch
            }
            if (landing == null) {
                Log.w("BalloonCoordinator", "updateTransportMode: no landing point, cannot calculate route")
                return@launch
            }
            val route = routingService.calculateRoute(
                location.point,
                landing.point,
                mode,
                settingsStore.settings.value.mapProvider
            )
            Log.d("BalloonCoordinator", "updateTransportMode: route calculated - distance=${route.distance}m, eta=${route.expectedTravelTime}s, points=${route.coordinates.size}")
            _route.value = route
            lastRouteOrigin = location.point
            lastRouteUpdate = Instant.now()
        }
    }

    fun updateSettings(settings: com.balloonhunter.app.domain.models.UserSettings) {
        scope.launch(Dispatchers.IO) {
            settingsStore.update(settings)
        }
    }

    // Device settings commands
    fun requestDeviceSettings() {
        bleService.requestSettings()
    }

    fun setMute(muted: Boolean) {
        bleService.setMute(muted)
    }

    fun setOLEDPins(sda: Int, scl: Int, rst: Int) {
        bleService.setOLEDPins(sda, scl, rst)
    }

    fun setLEDPin(pin: Int) {
        bleService.setLEDPin(pin)
    }

    fun setBuzzerPin(pin: Int) {
        bleService.setBuzzerPin(pin)
    }

    fun setBatterySettings(pin: Int, minVoltage: Int, maxVoltage: Int, dischargeType: Int) {
        bleService.setBatterySettings(pin, minVoltage, maxVoltage, dischargeType)
    }

    fun setCallSign(callSign: String) {
        bleService.setCallSign(callSign)
    }

    fun setRXBandwidth(rs41: Int?, m20: Int?, m10: Int?, pilot: Int?, dfm: Int?) {
        bleService.setRXBandwidth(rs41, m20, m10, pilot, dfm)
    }

    fun setLCDDriver(type: Int) {
        bleService.setLCDDriver(type)
    }

    fun setLCDOn(enabled: Boolean) {
        bleService.setLCDOn(enabled)
    }

    fun setBluetoothEnabled(enabled: Boolean) {
        bleService.setBluetooth(enabled)
    }

    fun setNameType(type: Int) {
        bleService.setNameType(type)
    }

    fun setFrequency(frequency: Double, probeType: String) {
        bleService.setFrequency(frequency, probeType)
    }

    fun setFrequencyCorrection(correction: Int) {
        bleService.sendSettings(mapOf("freqofs" to correction))
    }

    /**
     * Handle sonde name change - clear old data and fetch new sonde's track (like iOS clearAllSondeData)
     */
    private fun handleSondeChange(newSondeName: String) {
        if (newSondeName.isBlank()) return

        val oldName = currentSondeName

        // Clear and fetch on any sonde change OR on first sonde (oldName is null)
        // This ensures persisted track from different sonde is cleared on startup
        if (oldName != newSondeName) {
            if (oldName != null) {
                android.util.Log.i("BalloonCoordinator", "Sonde change detected: $oldName -> $newSondeName - clearing old data")
            } else {
                android.util.Log.i("BalloonCoordinator", "First sonde detected: $newSondeName - clearing any persisted data")
            }

            // Update current sonde name FIRST to prevent race conditions
            currentSondeName = newSondeName

            // Clear prediction data (not suspend)
            predictionService.clear()

            // Clear route
            _route.value = null
            lastRouteOrigin = null
            lastRouteUpdate = null

            // Clear all persisted data and fetch gap fill - must be sequential in IO context
            scope.launch(Dispatchers.IO) {
                // Clear track from memory AND database
                trackService.clearTrack()

                // Clear landing history from memory AND database
                landingService.clear()

                // Then fetch historical track from SondeHub for new sonde
                val historyPoints = aprsService.fetchGapFill(newSondeName)
                if (historyPoints.isNotEmpty()) {
                    trackService.insertGapFill(historyPoints)
                }
            }
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
        // Background policy: only BLE remains active in background
        // APRS, prediction, and location services are paused
        when (state) {
            DataState.STARTUP, DataState.NO_TELEMETRY -> {
                if (!isInBackground) {
                    aprsService.startPolling()
                    locationService.startBackgroundUpdates()
                }
                predictionService.stopTimer()
            }
            DataState.LIVE_BLE_FLYING -> {
                aprsService.stopPolling()
                if (!isInBackground) {
                    predictionService.startTimer(
                        positionProvider = { positionService.currentPosition.value },
                        settingsProvider = { settingsStore.settings.value },
                        phaseProvider = { positionService.balloonPhase.value },
                        adjustedDescentRateProvider = { trackService.adjustedDescentRate.value }
                    )
                    predictionServiceScopeTrigger()
                }
            }
            DataState.LIVE_BLE_LANDED -> {
                aprsService.stopPolling()
                predictionService.stopTimer()
                positionService.currentPosition.value?.let { position ->
                    scope.launch { landingService.updateLandingPoint(position.point, null, LandingPredictionSource.MANUAL) }
                }
            }
            DataState.WAITING_FOR_APRS -> {
                if (!isInBackground) {
                    aprsService.startPolling()
                }
                startWaitingTimeout()
            }
            DataState.APRS_FLYING -> {
                if (!isInBackground) {
                    aprsService.startPolling()
                    predictionService.startTimer(
                        positionProvider = { positionService.currentPosition.value },
                        settingsProvider = { settingsStore.settings.value },
                        phaseProvider = { positionService.balloonPhase.value },
                        adjustedDescentRateProvider = { trackService.adjustedDescentRate.value }
                    )
                    predictionServiceScopeTrigger()
                }
            }
            DataState.APRS_LANDED -> {
                if (!isInBackground) {
                    aprsService.startPolling()
                }
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
            val route = routingService.calculateRoute(location.point, point.point, _transportMode.value, settingsStore.settings.value.mapProvider)
            _route.value = route
            lastRouteOrigin = location.point
            lastRouteUpdate = Instant.now()
        }
        (notificationSink as? NotificationHelper)?.notifyNavigationUpdate(point, _transportMode.value)
    }

    /**
     * Check if BLE and APRS frequencies differ and show mismatch dialog if needed.
     */
    private fun checkFrequencyMismatch() {
        // Only check if we have both BLE radio data and APRS position data
        val bleRadio = bleService.radioUpdates.replayCache.lastOrNull() ?: return
        latestAprs ?: return

        // Check if mismatch is deferred
        val deferredUntil = mismatchDeferredUntil
        if (deferredUntil != null && Instant.now().isBefore(deferredUntil)) {
            return
        }

        // Get APRS frequency from position data (if available via AprsService)
        val aprsFrequency = aprsService.currentFrequency.value ?: return
        val aprsProbeType = aprsService.currentProbeType.value ?: return

        val bleFrequency = bleRadio.frequency
        val bleProbeType = bleRadio.probeType

        // Check for mismatch (frequency difference > 0.01 MHz or different probe type)
        val freqMismatch = kotlin.math.abs(bleFrequency - aprsFrequency) > 0.01
        val typeMismatch = !bleProbeType.equals(aprsProbeType, ignoreCase = true)

        if (freqMismatch || typeMismatch) {
            _frequencyMismatch.value = FrequencyMismatch(
                bleFrequency = bleFrequency,
                bleProbeType = bleProbeType,
                aprsFrequency = aprsFrequency,
                aprsProbeType = aprsProbeType
            )
        } else {
            _frequencyMismatch.value = null
        }
    }

    /**
     * Accept the frequency mismatch - update BLE device to APRS frequency.
     */
    fun acceptFrequencyMismatch() {
        val mismatch = _frequencyMismatch.value ?: return
        setFrequency(mismatch.aprsFrequency, mismatch.aprsProbeType)
        _frequencyMismatch.value = null
        mismatchDeferredUntil = null
    }

    /**
     * Dismiss the frequency mismatch - defer for 5 minutes.
     */
    fun dismissFrequencyMismatch() {
        _frequencyMismatch.value = null
        mismatchDeferredUntil = Instant.now().plusSeconds(300) // 5 minutes
    }
}
