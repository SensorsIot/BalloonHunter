package com.balloonhunter.app.presentation

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Directions
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.balloonhunter.app.domain.models.TransportationMode
import com.balloonhunter.app.presentation.state.MapViewModel
import com.google.android.gms.maps.CameraUpdateFactory
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.LatLng
import com.google.android.gms.maps.model.LatLngBounds
import com.google.android.gms.maps.GoogleMap
import com.google.maps.android.compose.GoogleMap as GoogleMapCompose
import com.google.maps.android.compose.MapProperties
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.Marker
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.Polyline
import com.google.maps.android.compose.rememberCameraPositionState

@Composable
fun MapScreen(viewModel: MapViewModel = hiltViewModel()) {
    val balloonPosition by viewModel.position.collectAsState()
    val track by viewModel.track.collectAsState()
    val prediction by viewModel.prediction.collectAsState()
    val landing by viewModel.currentLanding.collectAsState()
    val route by viewModel.route.collectAsState()
    val headingMode by viewModel.headingMode.collectAsState()
    val satelliteMode by viewModel.satelliteMode.collectAsState()
    val showAll by viewModel.showAll.collectAsState()
    val transportMode by viewModel.transportMode.collectAsState()

    val context = LocalContext.current
    val cameraPositionState = rememberCameraPositionState {
        position = balloonPosition?.let {
            CameraPosition.fromLatLngZoom(it.point.toLatLng(), 8f)
        } ?: CameraPosition.fromLatLngZoom(LatLng(0.0, 0.0), 2f)
    }

    LaunchedEffect(showAll, track, prediction, landing) {
        if (showAll) {
            val bounds = buildBounds(track.map { it.point } +
                (prediction?.path ?: emptyList()) +
                (landing?.point?.let { listOf(it) } ?: emptyList()))
            if (bounds != null) {
                cameraPositionState.animate(CameraUpdateFactory.newLatLngBounds(bounds, 64))
            }
            viewModel.toggleShowAll()
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        TopControls(
            transportMode = transportMode,
            headingMode = headingMode,
            onHeadingToggle = { viewModel.toggleHeading() },
            onShowAll = { viewModel.toggleShowAll() },
            onTransportMode = { viewModel.setTransportMode(it) },
            onNavigate = {
                landing?.let {
                    val uri = Uri.parse("google.navigation:q=${it.latitude},${it.longitude}&mode=${if (transportMode == TransportationMode.BIKE) "b" else "d"}")
                    val intent = Intent(Intent.ACTION_VIEW, uri)
                    context.startActivity(intent)
                }
            },
            navigationEnabled = landing != null
        )

        Box(modifier = Modifier.weight(0.7f).fillMaxWidth()) {
            GoogleMapCompose(
                modifier = Modifier.fillMaxSize(),
                cameraPositionState = cameraPositionState,
                properties = MapProperties(
                    mapType = if (satelliteMode) GoogleMap.MAP_TYPE_HYBRID else GoogleMap.MAP_TYPE_NORMAL,
                    isMyLocationEnabled = false
                ),
                uiSettings = MapUiSettings(
                    zoomControlsEnabled = false,
                    myLocationButtonEnabled = false,
                    scrollGesturesEnabled = !headingMode,
                    tiltGesturesEnabled = !headingMode
                )
            ) {
                if (track.isNotEmpty()) {
                    Polyline(
                        points = track.map { it.point.toLatLng() },
                        color = Color.Red,
                        width = 6f
                    )
                }

                prediction?.path?.let { path ->
                    Polyline(points = path.map { it.toLatLng() }, color = Color.Blue, width = 4f)
                }

                route?.let { routeData ->
                    Polyline(points = routeData.coordinates.map { it.toLatLng() }, color = Color.Green, width = 5f)
                }

                landing?.let {
                    Marker(
                        state = remember(it) { MarkerState(position = it.point.toLatLng()) },
                        title = "Landing"
                    )
                }

                val pos = balloonPosition
                if (pos != null) {
                    Marker(
                        state = remember(pos) { MarkerState(position = pos.point.toLatLng()) },
                        title = pos.sondeName.ifBlank { "Balloon" }
                    )
                }
            }
        }

        DataPanel(modifier = Modifier.weight(0.3f).fillMaxWidth(), viewModel = viewModel)
    }
}

@Composable
private fun TopControls(
    transportMode: TransportationMode,
    headingMode: Boolean,
    onHeadingToggle: () -> Unit,
    onShowAll: () -> Unit,
    onTransportMode: (TransportationMode) -> Unit,
    onNavigate: () -> Unit,
    navigationEnabled: Boolean
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .padding(8.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Button(onClick = { /* settings */ }, contentPadding = ButtonDefaults.ContentPadding) {
            Icon(Icons.Default.Settings, contentDescription = "Settings")
        }

        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            TextButton(onClick = { onTransportMode(TransportationMode.CAR) }) {
                Text("Car", color = if (transportMode == TransportationMode.CAR) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface)
            }
            TextButton(onClick = { onTransportMode(TransportationMode.BIKE) }) {
                Text("Bike", color = if (transportMode == TransportationMode.BIKE) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface)
            }
        }

        Button(onClick = onShowAll) { Text("Show All") }

        Button(onClick = onHeadingToggle) {
            Icon(Icons.Default.MyLocation, contentDescription = "Heading")
        }

        Button(onClick = { /* mute toggle */ }) {
            Icon(Icons.Default.VolumeUp, contentDescription = "Mute")
        }

        Button(onClick = onNavigate, enabled = navigationEnabled) {
            Icon(Icons.Default.Directions, contentDescription = "Navigate")
        }
    }
}

private fun buildBounds(points: List<com.balloonhunter.app.domain.models.GeoPoint>): LatLngBounds? {
    if (points.isEmpty()) return null
    val builder = LatLngBounds.Builder()
    points.forEach { builder.include(it.toLatLng()) }
    return builder.build()
}
