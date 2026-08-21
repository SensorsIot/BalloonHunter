package com.balloonhunter.app.domain.services

import com.balloonhunter.app.domain.models.BalloonPhase
import com.balloonhunter.app.domain.models.BLEConnectionState
import com.balloonhunter.app.domain.models.DataState
import com.balloonhunter.app.domain.models.PositionData
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

class BalloonPositionService {
    private val _dataState = MutableStateFlow(DataState.STARTUP)
    val dataState: StateFlow<DataState> = _dataState.asStateFlow()

    private val _currentPosition = MutableStateFlow<PositionData?>(null)
    val currentPosition: StateFlow<PositionData?> = _currentPosition.asStateFlow()

    private val _balloonPhase = MutableStateFlow(BalloonPhase.UNKNOWN)
    val balloonPhase: StateFlow<BalloonPhase> = _balloonPhase.asStateFlow()

    private val _bleConnectionState = MutableStateFlow(BLEConnectionState.NOT_CONNECTED)
    val bleConnectionState: StateFlow<BLEConnectionState> = _bleConnectionState.asStateFlow()

    private val _bleHasTelemetry = MutableStateFlow(false)
    private val _aprsDataAvailable = MutableStateFlow(false)
    private val _startupComplete = MutableStateFlow(false)

    fun setBleConnectionState(state: BLEConnectionState) {
        _bleConnectionState.value = state
    }

    fun setBleTelemetryAvailable(hasTelemetry: Boolean) {
        _bleHasTelemetry.value = hasTelemetry
        evaluateState()
    }

    fun setAprsDataAvailable(available: Boolean) {
        _aprsDataAvailable.value = available
        evaluateState()
    }

    fun setStartupComplete(complete: Boolean) {
        _startupComplete.value = complete
        evaluateState()
    }

    fun updatePosition(position: PositionData?) {
        _currentPosition.value = position
    }

    fun updateBalloonPhase(phase: BalloonPhase) {
        _balloonPhase.value = phase
        evaluateState()
    }

    fun forceNoTelemetry() {
        _dataState.value = DataState.NO_TELEMETRY
    }

    private fun evaluateState() {
        val bleTelemetry = _bleHasTelemetry.value
        val aprsData = _aprsDataAvailable.value
        val phase = _balloonPhase.value
        val startupComplete = _startupComplete.value
        val landed = phase == BalloonPhase.LANDED

        val current = _dataState.value
        val next = when (current) {
            DataState.STARTUP -> {
                if (!startupComplete) DataState.STARTUP
                else if (bleTelemetry && landed) DataState.LIVE_BLE_LANDED
                else if (bleTelemetry) DataState.LIVE_BLE_FLYING
                else if (aprsData && landed) DataState.APRS_LANDED
                else if (aprsData) DataState.APRS_FLYING
                else DataState.NO_TELEMETRY
            }
            DataState.LIVE_BLE_FLYING, DataState.LIVE_BLE_LANDED -> {
                if (!bleTelemetry) DataState.WAITING_FOR_APRS
                else if (landed) DataState.LIVE_BLE_LANDED else DataState.LIVE_BLE_FLYING
            }
            DataState.WAITING_FOR_APRS -> {
                if (bleTelemetry) {
                    if (landed) DataState.LIVE_BLE_LANDED else DataState.LIVE_BLE_FLYING
                } else if (aprsData) {
                    if (landed) DataState.APRS_LANDED else DataState.APRS_FLYING
                } else {
                    DataState.WAITING_FOR_APRS
                }
            }
            DataState.APRS_FLYING -> {
                if (bleTelemetry) DataState.LIVE_BLE_FLYING
                else if (landed) DataState.APRS_LANDED
                else if (!aprsData) DataState.NO_TELEMETRY
                else DataState.APRS_FLYING
            }
            DataState.APRS_LANDED -> {
                if (bleTelemetry) {
                    if (landed) DataState.LIVE_BLE_LANDED else DataState.LIVE_BLE_FLYING
                } else if (!landed) {
                    DataState.APRS_FLYING
                } else if (!aprsData) {
                    DataState.NO_TELEMETRY
                } else {
                    DataState.APRS_LANDED
                }
            }
            DataState.NO_TELEMETRY -> {
                if (bleTelemetry && landed) DataState.LIVE_BLE_LANDED
                else if (bleTelemetry) DataState.LIVE_BLE_FLYING
                else if (aprsData && landed) DataState.APRS_LANDED
                else if (aprsData) DataState.APRS_FLYING
                else DataState.NO_TELEMETRY
            }
        }

        if (current != next) {
            _dataState.value = next
        }
    }
}
