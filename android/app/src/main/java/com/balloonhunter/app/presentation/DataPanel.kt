package com.balloonhunter.app.presentation

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowCircleDown
import androidx.compose.material.icons.filled.ArrowCircleUp
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.BluetoothDisabled
import androidx.compose.material.icons.filled.GpsFixed
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.QuestionMark
import androidx.compose.material3.Icon
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.balloonhunter.app.domain.models.BLEConnectionState
import com.balloonhunter.app.domain.models.BalloonPhase
import com.balloonhunter.app.domain.models.DataState
import com.balloonhunter.app.domain.models.TelemetrySource
import com.balloonhunter.app.presentation.state.MapViewModel
import kotlinx.coroutines.delay
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

@Composable
fun DataPanel(modifier: Modifier = Modifier, viewModel: MapViewModel) {
    val position by viewModel.position.collectAsState()
    val track by viewModel.track.collectAsState()
    val prediction by viewModel.prediction.collectAsState()
    val dataState by viewModel.dataState.collectAsState()
    val bleConnectionState by viewModel.bleConnectionState.collectAsState()
    val balloonPhase by viewModel.balloonPhase.collectAsState()

    val placeholder = dataState == DataState.STARTUP || dataState == DataState.NO_TELEMETRY
    val isAprsMode = dataState == DataState.APRS_FLYING || dataState == DataState.APRS_LANDED
    val timeFormatter = DateTimeFormatter.ofPattern("HH:mm").withZone(ZoneId.systemDefault())

    // Determine frame color based on state
    val frameColor = when {
        bleConnectionState == BLEConnectionState.DATA_READY -> Color(0xFF4CAF50) // Green for BLE active
        dataState == DataState.APRS_FLYING || dataState == DataState.APRS_LANDED -> Color(0xFF2196F3) // Blue for APRS
        dataState == DataState.NO_TELEMETRY -> Color(0xFFF44336) // Red for no telemetry
        else -> Color.Transparent
    }

    // Check for stale telemetry (>60 seconds old) - only for BLE, not APRS
    val isStale = position?.let { pos ->
        pos.telemetrySource == TelemetrySource.BLE &&
            Duration.between(pos.timestamp, Instant.now()).seconds > 60
    } ?: false

    // BLE flash animation when new data arrives
    var flashActive by remember { mutableStateOf(false) }
    LaunchedEffect(position?.timestamp) {
        if (position?.telemetrySource == TelemetrySource.BLE) {
            flashActive = true
            delay(300)
            flashActive = false
        }
    }

    val animatedBgColor by animateColorAsState(
        targetValue = if (isStale) Color(0xFFFFEB3B).copy(alpha = 0.2f) // Yellow tint for stale
        else MaterialTheme.colorScheme.surfaceVariant,
        animationSpec = tween(durationMillis = 150),
        label = "bgColor"
    )

    // Connection icon color (BLE or APRS)
    val connectionIconColor by animateColorAsState(
        targetValue = when {
            isAprsMode -> Color(0xFF2196F3) // Blue for APRS
            flashActive -> Color(0xFF4CAF50) // Bright green flash for BLE
            bleConnectionState == BLEConnectionState.DATA_READY -> Color(0xFF4CAF50).copy(alpha = 0.8f) // Green for BLE connected
            bleConnectionState == BLEConnectionState.READY_FOR_COMMANDS -> Color(0xFFFFA500) // Orange for BLE ready but no data
            else -> Color.Gray.copy(alpha = 0.4f) // Gray for disconnected
        },
        animationSpec = tween(durationMillis = 150),
        label = "connectionIconColor"
    )

    // Flight status icon color based on balloon phase
    val flightStatusIconColor = when (balloonPhase) {
        BalloonPhase.ASCENDING -> Color(0xFF4CAF50) // Green for ascending
        BalloonPhase.DESCENDING_ABOVE_10K -> Color(0xFFFFA500) // Orange for high altitude descent
        BalloonPhase.DESCENDING_BELOW_10K -> Color(0xFFF44336) // Red for low altitude descent
        BalloonPhase.LANDED -> Color(0xFF9C27B0) // Purple for landed
        BalloonPhase.UNKNOWN -> Color.Gray // Gray for unknown
    }

    val altitude = position?.altitude?.let { "%.0f m".format(it) } ?: "--"
    val freq = position?.let { "--" } ?: "--"
    val vSpeed = position?.verticalSpeed?.let { "%.2f m/s".format(it) } ?: "--"
    val hSpeed = position?.horizontalSpeed?.let { "%.1f km/h".format(it * 3.6) } ?: "--"
    val distance = position?.let { "--" } ?: "--"
    val flightTime = track.firstOrNull()?.timestamp?.let { start ->
        val dur = Duration.between(start, Instant.now())
        "${dur.toHours().toString().padStart(2, '0')}:${(dur.toMinutes() % 60).toString().padStart(2, '0')}"
    } ?: "--"
    val landingTime = prediction?.landingTime?.let { timeFormatter.format(it) } ?: "--"

    Column(
        modifier = modifier
            .fillMaxSize()
            .border(
                width = if (frameColor != Color.Transparent) 3.dp else 0.dp,
                color = frameColor,
                shape = RoundedCornerShape(4.dp)
            )
            .background(animatedBgColor)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        // First row with status icons: Connection, Flight Status, Sonde Name, Altitude
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            // Connection icon (BLE or APRS)
            Icon(
                imageVector = if (isAprsMode) Icons.Default.Public
                    else if (bleConnectionState == BLEConnectionState.NOT_CONNECTED) Icons.Default.BluetoothDisabled
                    else Icons.Default.Bluetooth,
                contentDescription = if (isAprsMode) "APRS" else "BLE Status",
                modifier = Modifier.size(28.dp),
                tint = connectionIconColor
            )
            // Flight status icon
            Icon(
                imageVector = when (balloonPhase) {
                    BalloonPhase.ASCENDING -> Icons.Default.ArrowCircleUp
                    BalloonPhase.DESCENDING_ABOVE_10K, BalloonPhase.DESCENDING_BELOW_10K -> Icons.Default.ArrowCircleDown
                    BalloonPhase.LANDED -> Icons.Default.GpsFixed
                    BalloonPhase.UNKNOWN -> Icons.Default.QuestionMark
                },
                contentDescription = when (balloonPhase) {
                    BalloonPhase.ASCENDING -> "Ascending"
                    BalloonPhase.DESCENDING_ABOVE_10K -> "Descending (high)"
                    BalloonPhase.DESCENDING_BELOW_10K -> "Descending (low)"
                    BalloonPhase.LANDED -> "Landed"
                    BalloonPhase.UNKNOWN -> "Unknown"
                },
                modifier = Modifier.size(28.dp),
                tint = flightStatusIconColor
            )
            // Sonde name
            Text(
                text = if (placeholder) "--" else position?.sondeName ?: "--",
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.weight(1f)
            )
            // Altitude
            Text(
                text = if (placeholder) "--" else altitude,
                style = MaterialTheme.typography.titleLarge
            )
        }
        DataRow("V Speed", if (placeholder) "--" else vSpeed, "H Speed", if (placeholder) "--" else hSpeed)
        DataRow("Flight", if (placeholder) "--" else flightTime, "Landing", if (placeholder) "--" else landingTime)
        DataRow("Freq", if (placeholder) "--" else freq, "Distance", if (placeholder) "--" else distance)
    }
}

@Composable
private fun DataRow(leftLabel: String, leftValue: String, rightLabel: String, rightValue: String) {
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Column(modifier = Modifier.weight(1f)) {
            Text(text = leftLabel, style = MaterialTheme.typography.labelLarge)
            Text(text = leftValue, style = MaterialTheme.typography.titleLarge)
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(text = rightLabel, style = MaterialTheme.typography.labelLarge)
            Text(text = rightValue, style = MaterialTheme.typography.titleLarge)
        }
    }
}
