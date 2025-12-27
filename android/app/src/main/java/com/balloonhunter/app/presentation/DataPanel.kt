package com.balloonhunter.app.presentation

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.balloonhunter.app.domain.models.DataState
import com.balloonhunter.app.presentation.state.MapViewModel
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

    val placeholder = dataState == DataState.STARTUP || dataState == DataState.NO_TELEMETRY
    val timeFormatter = DateTimeFormatter.ofPattern("HH:mm").withZone(ZoneId.systemDefault())

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
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        DataRow("Sonde", if (placeholder) "--" else position?.sondeName ?: "--", "Alt", if (placeholder) "--" else altitude)
        DataRow("V Speed", if (placeholder) "--" else vSpeed, "H Speed", if (placeholder) "--" else hSpeed)
        DataRow("Flight", if (placeholder) "--" else flightTime, "Landing", if (placeholder) "--" else landingTime)
        DataRow("Freq", if (placeholder) "--" else freq, "Distance", if (placeholder) "--" else distance)
    }
}

@Composable
private fun DataRow(leftLabel: String, leftValue: String, rightLabel: String, rightValue: String) {
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Column(modifier = Modifier.weight(1f)) {
            Text(text = leftLabel, style = MaterialTheme.typography.labelSmall)
            Text(text = leftValue, style = MaterialTheme.typography.bodyMedium)
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(text = rightLabel, style = MaterialTheme.typography.labelSmall)
            Text(text = rightValue, style = MaterialTheme.typography.bodyMedium)
        }
    }
}
