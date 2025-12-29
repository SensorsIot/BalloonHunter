package com.balloonhunter.app.presentation

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Directions
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.BluetoothSearching
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.balloonhunter.app.domain.models.BalloonPhase
import com.balloonhunter.app.domain.models.CameraUpdate
import com.balloonhunter.app.domain.models.MapAnnotationItem
import com.balloonhunter.app.domain.models.RadioChannelData
import com.balloonhunter.app.domain.models.TransportationMode
import com.balloonhunter.app.domain.models.UserSettings
import com.balloonhunter.app.presentation.state.MapViewModel
import com.google.accompanist.permissions.ExperimentalPermissionsApi
import com.google.accompanist.permissions.rememberMultiplePermissionsState
import com.google.android.gms.maps.CameraUpdateFactory
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.LatLng
import com.google.android.gms.maps.model.LatLngBounds
import com.google.maps.android.compose.Circle
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapProperties
import com.google.maps.android.compose.MapType
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.Marker
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.Polyline
import com.google.maps.android.compose.rememberCameraPositionState
import com.google.android.gms.maps.model.BitmapDescriptorFactory

@OptIn(ExperimentalPermissionsApi::class)
@Composable
fun MapScreen(viewModel: MapViewModel = hiltViewModel()) {
    val balloonPosition by viewModel.position.collectAsState()
    val balloonPhase by viewModel.balloonPhase.collectAsState()
    val track by viewModel.track.collectAsState()
    val prediction by viewModel.prediction.collectAsState()
    val landing by viewModel.currentLanding.collectAsState()
    val route by viewModel.route.collectAsState()
    val headingMode by viewModel.headingMode.collectAsState()
    val satelliteMode by viewModel.satelliteMode.collectAsState()
    val showAll by viewModel.showAll.collectAsState()
    val transportMode by viewModel.transportMode.collectAsState()
    val userSettings by viewModel.userSettings.collectAsState()
    val annotations by viewModel.annotations.collectAsState()
    val cameraUpdate by viewModel.cameraUpdate.collectAsState()
    val frequencyMismatch by viewModel.frequencyMismatch.collectAsState()
    val routeVisible by viewModel.routeVisible.collectAsState()

    // Track mute state from radio data
    var isMuted by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        viewModel.radioData.collect { radio ->
            isMuted = radio.buzmute
        }
    }

    var showSettingsDialog by remember { mutableStateOf(false) }

    val context = LocalContext.current
    val cameraPositionState = rememberCameraPositionState {
        position = balloonPosition?.let {
            CameraPosition.fromLatLngZoom(it.point.toLatLng(), 8f)
        } ?: CameraPosition.fromLatLngZoom(LatLng(0.0, 0.0), 2f)
    }

    val permissionsState = rememberMultiplePermissionsState(
        permissions = listOf(
            android.Manifest.permission.ACCESS_FINE_LOCATION,
            android.Manifest.permission.BLUETOOTH_SCAN,
            android.Manifest.permission.BLUETOOTH_CONNECT
        )
    )

    LaunchedEffect(Unit) {
        permissionsState.launchMultiplePermissionRequest()
    }

    // Handle camera updates from ViewModel
    LaunchedEffect(cameraUpdate) {
        when (val update = cameraUpdate) {
            is CameraUpdate.FitBounds -> {
                val bounds = buildBounds(update.points)
                if (bounds != null) {
                    cameraPositionState.animate(CameraUpdateFactory.newLatLngBounds(bounds, update.padding))
                }
                viewModel.consumeCameraUpdate()
            }
            is CameraUpdate.CenterOn -> {
                val zoom = update.zoom ?: cameraPositionState.position.zoom
                cameraPositionState.animate(CameraUpdateFactory.newLatLngZoom(update.point.toLatLng(), zoom))
                viewModel.consumeCameraUpdate()
            }
            is CameraUpdate.FollowHeading -> {
                val newPos = CameraPosition.builder()
                    .target(update.point.toLatLng())
                    .zoom(update.zoom)
                    .bearing(update.heading)
                    .build()
                cameraPositionState.animate(CameraUpdateFactory.newCameraPosition(newPos))
                viewModel.consumeCameraUpdate()
            }
            null -> { /* No update pending */ }
        }
    }

    // Trigger fit-all when showAll is toggled
    LaunchedEffect(showAll) {
        if (showAll) {
            viewModel.requestFitAll()
            viewModel.toggleShowAll()
        }
    }

    Column(modifier = Modifier
        .fillMaxSize()
        .windowInsetsPadding(WindowInsets.statusBars)
    ) {
        TopControls(
            transportMode = transportMode,
            headingMode = headingMode,
            isMuted = isMuted,
            onHeadingToggle = { viewModel.toggleHeading() },
            onShowAll = { viewModel.toggleShowAll() },
            onTransportMode = { viewModel.setTransportMode(it) },
            onMuteToggle = {
                isMuted = !isMuted
                viewModel.setMute(isMuted)
            },
            onNavigate = {
                landing?.let {
                    val mode = if (transportMode == TransportationMode.BIKE) "b" else "d"
                    val gmmIntentUri = Uri.parse("google.navigation:q=${it.latitude},${it.longitude}&mode=$mode")
                    val mapIntent = Intent(Intent.ACTION_VIEW, gmmIntentUri)
                    mapIntent.setPackage("com.google.android.apps.maps")

                    // Try Google Maps first, fallback to any available maps app
                    try {
                        if (mapIntent.resolveActivity(context.packageManager) != null) {
                            context.startActivity(mapIntent)
                        } else {
                            // Fallback to geo URI that any maps app can handle
                            val fallbackUri = Uri.parse("geo:${it.latitude},${it.longitude}?q=${it.latitude},${it.longitude}(Landing)")
                            val fallbackIntent = Intent(Intent.ACTION_VIEW, fallbackUri)
                            context.startActivity(fallbackIntent)
                        }
                    } catch (e: Exception) {
                        // Last resort: open in browser
                        val browserUri = Uri.parse("https://www.google.com/maps/dir/?api=1&destination=${it.latitude},${it.longitude}&travelmode=${if (mode == "b") "bicycling" else "driving"}")
                        val browserIntent = Intent(Intent.ACTION_VIEW, browserUri)
                        context.startActivity(browserIntent)
                    }
                }
            },
            navigationEnabled = landing != null,
            onResetBle = { viewModel.resetBle() },
            onSettings = { showSettingsDialog = true }
        )

        if (showSettingsDialog) {
            UnifiedSettingsDialog(
                viewModel = viewModel,
                userSettings = userSettings,
                onSaveUserSettings = { newSettings ->
                    viewModel.updateSettings(newSettings)
                },
                onDismiss = { showSettingsDialog = false }
            )
        }

        // Frequency mismatch confirmation dialog
        frequencyMismatch?.let { mismatch ->
            AlertDialog(
                onDismissRequest = { viewModel.dismissFrequencyMismatch() },
                title = { Text("Frequency Mismatch") },
                text = {
                    Column {
                        Text("The connected MySondyGO has a different frequency than the APRS data.")
                        Spacer(modifier = Modifier.height(8.dp))
                        Text("MySondyGO: ${mismatch.bleProbeType} @ ${String.format("%.2f", mismatch.bleFrequency)} MHz")
                        Text("APRS: ${mismatch.aprsProbeType} @ ${String.format("%.2f", mismatch.aprsFrequency)} MHz")
                        Spacer(modifier = Modifier.height(8.dp))
                        Text("Do you want to update MySondyGO to match the APRS frequency?")
                    }
                },
                confirmButton = {
                    TextButton(onClick = { viewModel.acceptFrequencyMismatch() }) {
                        Text("Update")
                    }
                },
                dismissButton = {
                    TextButton(onClick = { viewModel.dismissFrequencyMismatch() }) {
                        Text("Later (5 min)")
                    }
                }
            )
        }

        Box(modifier = Modifier.weight(0.7f).fillMaxWidth()) {
            GoogleMap(
                modifier = Modifier.fillMaxSize(),
                cameraPositionState = cameraPositionState,
                properties = MapProperties(
                    mapType = if (satelliteMode) MapType.HYBRID else MapType.NORMAL,
                    isMyLocationEnabled = permissionsState.allPermissionsGranted
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
                    Polyline(points = path.map { it.toLatLng() }, color = Color(0xFF00AAFF), width = 8f)
                }

                // Burst marker - only visible while ascending
                if (balloonPhase == BalloonPhase.ASCENDING) {
                    prediction?.burstPoint?.let { burstPoint ->
                        Marker(
                            state = remember(burstPoint) { MarkerState(position = burstPoint.toLatLng()) },
                            title = "Burst Point",
                            icon = BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_ORANGE)
                        )
                    }
                }

                // Route polyline - hidden if user within 100m of balloon
                if (routeVisible) {
                    route?.let { routeData ->
                        Polyline(points = routeData.coordinates.map { it.toLatLng() }, color = Color.Green, width = 5f)
                    }
                }

                // Landing history overlay - purple polyline + dots
                val landingHistoryPoints by viewModel.landingHistory.collectAsState()
                if (landingHistoryPoints.size >= 2) {
                    Polyline(
                        points = landingHistoryPoints.map { it.point.toLatLng() },
                        color = Color(0xFF9C27B0), // Purple
                        width = 3f
                    )
                }
                landingHistoryPoints.forEach { historyPoint ->
                    Circle(
                        center = historyPoint.point.toLatLng(),
                        radius = 20.0,
                        fillColor = Color(0xFF9C27B0).copy(alpha = 0.7f),
                        strokeColor = Color(0xFF9C27B0),
                        strokeWidth = 2f
                    )
                }

                landing?.let {
                    Marker(
                        state = remember(it) { MarkerState(position = it.point.toLatLng()) },
                        title = "Landing",
                        icon = BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_VIOLET)
                    )
                }

                val pos = balloonPosition
                if (pos != null) {
                    val balloonHue = when (balloonPhase) {
                        BalloonPhase.ASCENDING -> BitmapDescriptorFactory.HUE_GREEN
                        BalloonPhase.DESCENDING_ABOVE_10K -> BitmapDescriptorFactory.HUE_ORANGE
                        BalloonPhase.DESCENDING_BELOW_10K -> BitmapDescriptorFactory.HUE_RED
                        BalloonPhase.LANDED -> BitmapDescriptorFactory.HUE_VIOLET
                        BalloonPhase.UNKNOWN -> BitmapDescriptorFactory.HUE_AZURE
                    }
                    Marker(
                        state = remember(pos) { MarkerState(position = pos.point.toLatLng()) },
                        title = pos.sondeName.ifBlank { "Balloon" },
                        icon = BitmapDescriptorFactory.defaultMarker(balloonHue)
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
    isMuted: Boolean,
    onHeadingToggle: () -> Unit,
    onShowAll: () -> Unit,
    onTransportMode: (TransportationMode) -> Unit,
    onMuteToggle: () -> Unit,
    onNavigate: () -> Unit,
    navigationEnabled: Boolean,
    onResetBle: () -> Unit,
    onSettings: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 8.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        IconButton(onClick = onSettings) {
            Icon(Icons.Default.Settings, contentDescription = "Settings")
        }

        // Mute button - placed early for visibility
        IconButton(onClick = onMuteToggle) {
            Icon(
                if (isMuted) Icons.Default.VolumeOff else Icons.Default.VolumeUp,
                contentDescription = if (isMuted) "Unmute" else "Mute",
                tint = if (isMuted) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface
            )
        }

        IconButton(onClick = onResetBle) {
            Icon(Icons.Default.BluetoothSearching, contentDescription = "Reset BLE")
        }

        TextButton(onClick = { onTransportMode(TransportationMode.CAR) }) {
            Text("Car", color = if (transportMode == TransportationMode.CAR) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface)
        }
        TextButton(onClick = { onTransportMode(TransportationMode.BIKE) }) {
            Text("Bike", color = if (transportMode == TransportationMode.BIKE) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface)
        }

        Button(onClick = onShowAll) { Text("All") }

        IconButton(onClick = onHeadingToggle) {
            Icon(
                Icons.Default.MyLocation,
                contentDescription = "Heading",
                tint = if (headingMode) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface
            )
        }

        IconButton(onClick = onNavigate, enabled = navigationEnabled) {
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun UnifiedSettingsDialog(
    viewModel: MapViewModel,
    userSettings: UserSettings,
    onSaveUserSettings: (UserSettings) -> Unit,
    onDismiss: () -> Unit
) {
    // 0 = App, 1 = Device
    var selectedMainTab by remember { mutableStateOf(0) }

    // App settings state
    var stationId by remember(userSettings) { mutableStateOf(userSettings.stationId) }
    var burstAltitude by remember(userSettings) { mutableStateOf(userSettings.burstAltitude.toString()) }
    var ascentRate by remember(userSettings) { mutableStateOf(userSettings.ascentRate.toString()) }
    var descentRate by remember(userSettings) { mutableStateOf(userSettings.descentRate.toString()) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Settings") },
        text = {
            Column(modifier = Modifier.fillMaxWidth()) {
                TabRow(selectedTabIndex = selectedMainTab) {
                    Tab(
                        selected = selectedMainTab == 0,
                        onClick = { selectedMainTab = 0 },
                        text = { Text("App") }
                    )
                    Tab(
                        selected = selectedMainTab == 1,
                        onClick = { selectedMainTab = 1 },
                        text = { Text("Device") }
                    )
                }

                Spacer(modifier = Modifier.height(16.dp))

                when (selectedMainTab) {
                    0 -> {
                        // App settings
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedTextField(
                                value = stationId,
                                onValueChange = { stationId = it },
                                label = { Text("Station ID") },
                                singleLine = true,
                                modifier = Modifier.fillMaxWidth()
                            )
                            OutlinedTextField(
                                value = burstAltitude,
                                onValueChange = { burstAltitude = it },
                                label = { Text("Burst Altitude (m)") },
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                singleLine = true,
                                modifier = Modifier.fillMaxWidth()
                            )
                            OutlinedTextField(
                                value = ascentRate,
                                onValueChange = { ascentRate = it },
                                label = { Text("Ascent Rate (m/s)") },
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                                singleLine = true,
                                modifier = Modifier.fillMaxWidth()
                            )
                            OutlinedTextField(
                                value = descentRate,
                                onValueChange = { descentRate = it },
                                label = { Text("Descent Rate (m/s)") },
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                                singleLine = true,
                                modifier = Modifier.fillMaxWidth()
                            )
                        }
                    }
                    1 -> {
                        // Device settings - directly embedded
                        DeviceSettingsContent(viewModel = viewModel)
                    }
                }
            }
        },
        confirmButton = {
            if (selectedMainTab == 0) {
                TextButton(onClick = {
                    val newSettings = userSettings.copy(
                        stationId = stationId,
                        burstAltitude = burstAltitude.toDoubleOrNull() ?: userSettings.burstAltitude,
                        ascentRate = ascentRate.toDoubleOrNull() ?: userSettings.ascentRate,
                        descentRate = descentRate.toDoubleOrNull() ?: userSettings.descentRate
                    )
                    onSaveUserSettings(newSettings)
                    onDismiss()
                }) {
                    Text("Save")
                }
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Close")
            }
        }
    )
}
