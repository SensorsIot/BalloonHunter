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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BluetoothSearching
import androidx.compose.material.icons.filled.Directions
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.PedalBike
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material.icons.filled.VolumeUp
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import kotlinx.coroutines.launch
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.ScrollableTabRow
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.balloonhunter.app.domain.models.BalloonPhase
import com.balloonhunter.app.domain.models.CameraUpdate
import com.balloonhunter.app.domain.models.MapAnnotationItem
import com.balloonhunter.app.domain.models.RadioChannelData
import com.balloonhunter.app.domain.models.TransportationMode
import com.balloonhunter.app.domain.models.UserSettings
import com.balloonhunter.app.domain.models.NavigationProvider
import com.balloonhunter.app.domain.models.MapProvider
import com.balloonhunter.app.presentation.map.GoogleMapContent
import com.balloonhunter.app.presentation.map.OsmMapContent
import com.balloonhunter.app.presentation.map.toLatLng
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

    // Handle camera updates from ViewModel - only for Google Maps
    // CameraUpdateFactory requires Google Maps to be initialized
    LaunchedEffect(cameraUpdate, userSettings.mapProvider) {
        if (userSettings.mapProvider == MapProvider.OSM) {
            // OSM handles camera internally, just consume the update
            if (cameraUpdate != null) {
                viewModel.consumeCameraUpdate()
            }
            return@LaunchedEffect
        }

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

    // Track fit-all trigger for OSM
    var osmFitAllTrigger by remember { mutableStateOf(0) }

    // Trigger fit-all when showAll is toggled
    LaunchedEffect(showAll) {
        if (showAll) {
            if (userSettings.mapProvider == MapProvider.OSM) {
                osmFitAllTrigger++
            } else {
                viewModel.requestFitAll()
            }
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
            satelliteMode = satelliteMode,
            mapProvider = userSettings.mapProvider,
            onHeadingToggle = { viewModel.toggleHeading() },
            onShowAll = { viewModel.toggleShowAll() },
            onTransportMode = { viewModel.setTransportMode(it) },
            onMuteToggle = {
                isMuted = !isMuted
                viewModel.setMute(isMuted)
            },
            onSatelliteToggle = { viewModel.toggleSatellite() },
            onNavigate = {
                landing?.let { landingPoint ->
                    val lat = landingPoint.latitude
                    val lon = landingPoint.longitude
                    val isBike = transportMode == TransportationMode.BIKE

                    when (userSettings.navigationProvider) {
                        NavigationProvider.GOOGLE_MAPS -> {
                            val mode = if (isBike) "b" else "d"
                            val gmmIntentUri = Uri.parse("google.navigation:q=$lat,$lon&mode=$mode")
                            val mapIntent = Intent(Intent.ACTION_VIEW, gmmIntentUri)
                            mapIntent.setPackage("com.google.android.apps.maps")

                            if (mapIntent.resolveActivity(context.packageManager) != null) {
                                context.startActivity(mapIntent)
                            } else {
                                android.widget.Toast.makeText(
                                    context,
                                    "Google Maps not installed. Change navigation app in settings.",
                                    android.widget.Toast.LENGTH_LONG
                                ).show()
                                showSettingsDialog = true
                            }
                        }
                        NavigationProvider.OSMAND -> {
                            // Check if OsmAnd is installed (free or plus version)
                            val osmandInstalled = try {
                                context.packageManager.getPackageInfo("net.osmand", 0)
                                true
                            } catch (e: Exception) {
                                try {
                                    context.packageManager.getPackageInfo("net.osmand.plus", 0)
                                    true
                                } catch (e: Exception) { false }
                            }

                            if (osmandInstalled) {
                                val osmandUri = Uri.parse("osmand.navigation:q=$lat,$lon")
                                context.startActivity(Intent(Intent.ACTION_VIEW, osmandUri))
                            } else {
                                android.widget.Toast.makeText(
                                    context,
                                    "OsmAnd not installed. Change navigation app in settings.",
                                    android.widget.Toast.LENGTH_LONG
                                ).show()
                                showSettingsDialog = true
                            }
                        }
                        NavigationProvider.ORGANIC_MAPS -> {
                            val organicInstalled = try {
                                context.packageManager.getPackageInfo("app.organicmaps", 0)
                                true
                            } catch (e: Exception) { false }

                            if (organicInstalled) {
                                val organicUri = Uri.parse("om://route?daddr=$lat,$lon")
                                context.startActivity(Intent(Intent.ACTION_VIEW, organicUri))
                            } else {
                                android.widget.Toast.makeText(
                                    context,
                                    "Organic Maps not installed. Change navigation app in settings.",
                                    android.widget.Toast.LENGTH_LONG
                                ).show()
                                showSettingsDialog = true
                            }
                        }
                    }
                }
            },
            navigationEnabled = landing != null,
            onSettings = { showSettingsDialog = true }
        )

        if (showSettingsDialog) {
            UnifiedSettingsDialog(
                viewModel = viewModel,
                userSettings = userSettings,
                onSaveUserSettings = { newSettings ->
                    viewModel.updateSettings(newSettings)
                    // Reset to car mode when switching to OSM (bike not supported)
                    if (newSettings.mapProvider == MapProvider.OSM && transportMode == TransportationMode.BIKE) {
                        viewModel.setTransportMode(TransportationMode.CAR)
                    }
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

        val landingHistoryPoints by viewModel.landingHistory.collectAsState()

        Box(modifier = Modifier.weight(0.7f).fillMaxWidth()) {
            when (userSettings.mapProvider) {
                MapProvider.GOOGLE_MAPS -> {
                    GoogleMapContent(
                        modifier = Modifier.fillMaxSize(),
                        cameraPositionState = cameraPositionState,
                        satelliteMode = satelliteMode,
                        headingMode = headingMode,
                        locationEnabled = permissionsState.allPermissionsGranted,
                        track = track,
                        prediction = prediction,
                        balloonPhase = balloonPhase,
                        balloonPosition = balloonPosition,
                        landing = landing,
                        landingHistory = landingHistoryPoints,
                        route = route,
                        routeVisible = routeVisible
                    )
                }
                MapProvider.OSM -> {
                    OsmMapContent(
                        modifier = Modifier.fillMaxSize(),
                        centerLat = balloonPosition?.latitude ?: 47.0,
                        centerLon = balloonPosition?.longitude ?: 8.0,
                        zoom = 10.0,
                        satelliteMode = satelliteMode,
                        track = track,
                        prediction = prediction,
                        balloonPhase = balloonPhase,
                        balloonPosition = balloonPosition,
                        landing = landing,
                        landingHistory = landingHistoryPoints,
                        route = route,
                        routeVisible = routeVisible,
                        fitAllTrigger = osmFitAllTrigger,
                        onMapMoved = { _, _, _ -> }
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
    satelliteMode: Boolean,
    mapProvider: MapProvider,
    onHeadingToggle: () -> Unit,
    onShowAll: () -> Unit,
    onTransportMode: (TransportationMode) -> Unit,
    onMuteToggle: () -> Unit,
    onSatelliteToggle: () -> Unit,
    onNavigate: () -> Unit,
    navigationEnabled: Boolean,
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

        // Map type toggle - standard/satellite
        IconButton(onClick = onSatelliteToggle) {
            Icon(
                if (satelliteMode) Icons.Default.Map else Icons.Default.Layers,
                contentDescription = if (satelliteMode) "Standard map" else "Satellite map",
                tint = if (satelliteMode) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface
            )
        }

        IconButton(onClick = { onTransportMode(TransportationMode.CAR) }) {
            Icon(
                Icons.Default.DirectionsCar,
                contentDescription = "Car",
                tint = if (transportMode == TransportationMode.CAR) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.4f)
            )
        }
        // Bike routing only available with Google Maps (OSRM doesn't support cycling)
        if (mapProvider == MapProvider.GOOGLE_MAPS) {
            IconButton(onClick = { onTransportMode(TransportationMode.BIKE) }) {
                Icon(
                    Icons.Default.PedalBike,
                    contentDescription = "Bike",
                    tint = if (transportMode == TransportationMode.BIKE) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.4f)
                )
            }
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
    // 0 = Frequency, 1 = App, 2 = Balloon, 3 = Device
    var selectedMainTab by remember { mutableStateOf(0) }

    // Balloon settings state
    var stationId by remember(userSettings) { mutableStateOf(userSettings.stationId) }
    var burstAltitude by remember(userSettings) { mutableStateOf(userSettings.burstAltitude.toString()) }
    var ascentRate by remember(userSettings) { mutableStateOf(userSettings.ascentRate.toString()) }
    var descentRate by remember(userSettings) { mutableStateOf(userSettings.descentRate.toString()) }

    // App settings state
    var navigationProvider by remember(userSettings) { mutableStateOf(userSettings.navigationProvider) }
    var mapProvider by remember(userSettings) { mutableStateOf(userSettings.mapProvider) }

    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()

    fun saveAndClose() {
        val newSettings = userSettings.copy(
            stationId = stationId,
            burstAltitude = burstAltitude.toDoubleOrNull() ?: userSettings.burstAltitude,
            ascentRate = ascentRate.toDoubleOrNull() ?: userSettings.ascentRate,
            descentRate = descentRate.toDoubleOrNull() ?: userSettings.descentRate,
            navigationProvider = navigationProvider,
            mapProvider = mapProvider
        )
        onSaveUserSettings(newSettings)
        scope.launch { sheetState.hide() }.invokeOnCompletion {
            if (!sheetState.isVisible) onDismiss()
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(bottom = 24.dp)
        ) {
            // Header with title and action buttons
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("Settings", style = MaterialTheme.typography.titleLarge)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (selectedMainTab == 1 || selectedMainTab == 2) {
                        TextButton(onClick = { saveAndClose() }) {
                            Text("Save")
                        }
                    }
                    TextButton(onClick = {
                        scope.launch { sheetState.hide() }.invokeOnCompletion {
                            if (!sheetState.isVisible) onDismiss()
                        }
                    }) {
                        Text("Close")
                    }
                }
            }

            Spacer(modifier = Modifier.height(8.dp))

            // Tab Row
            ScrollableTabRow(
                selectedTabIndex = selectedMainTab,
                edgePadding = 0.dp
            ) {
                Tab(
                    selected = selectedMainTab == 0,
                    onClick = { selectedMainTab = 0 },
                    text = { Text("Freq") }
                )
                Tab(
                    selected = selectedMainTab == 1,
                    onClick = { selectedMainTab = 1 },
                    text = { Text("App") }
                )
                Tab(
                    selected = selectedMainTab == 2,
                    onClick = { selectedMainTab = 2 },
                    text = { Text("Balloon") }
                )
                Tab(
                    selected = selectedMainTab == 3,
                    onClick = { selectedMainTab = 3 },
                    text = { Text("Device") }
                )
            }

            Spacer(modifier = Modifier.height(16.dp))

            when (selectedMainTab) {
                    0 -> {
                        // Frequency settings - Sonde type & frequency
                        FrequencySettingsTab(viewModel = viewModel)
                    }
                    1 -> {
                        // App settings - Navigation, Map, BLE reset
                        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                            // Map Display - Segmented buttons
                            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text("Map Display", style = MaterialTheme.typography.labelMedium)
                                SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                                    SegmentedButton(
                                        selected = mapProvider == MapProvider.GOOGLE_MAPS,
                                        onClick = { mapProvider = MapProvider.GOOGLE_MAPS },
                                        shape = SegmentedButtonDefaults.itemShape(index = 0, count = 2)
                                    ) {
                                        Text("Google Maps")
                                    }
                                    SegmentedButton(
                                        selected = mapProvider == MapProvider.OSM,
                                        onClick = { mapProvider = MapProvider.OSM },
                                        shape = SegmentedButtonDefaults.itemShape(index = 1, count = 2)
                                    ) {
                                        Text("OpenStreetMap")
                                    }
                                }
                                Text(
                                    text = if (mapProvider == MapProvider.OSM) "No API key needed" else "Requires API key",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }

                            // Navigation App - Segmented buttons (3 options)
                            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text("Navigation App", style = MaterialTheme.typography.labelMedium)
                                SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                                    SegmentedButton(
                                        selected = navigationProvider == NavigationProvider.GOOGLE_MAPS,
                                        onClick = { navigationProvider = NavigationProvider.GOOGLE_MAPS },
                                        shape = SegmentedButtonDefaults.itemShape(index = 0, count = 3)
                                    ) {
                                        Text("Google", maxLines = 1)
                                    }
                                    SegmentedButton(
                                        selected = navigationProvider == NavigationProvider.OSMAND,
                                        onClick = { navigationProvider = NavigationProvider.OSMAND },
                                        shape = SegmentedButtonDefaults.itemShape(index = 1, count = 3)
                                    ) {
                                        Text("OsmAnd", maxLines = 1)
                                    }
                                    SegmentedButton(
                                        selected = navigationProvider == NavigationProvider.ORGANIC_MAPS,
                                        onClick = { navigationProvider = NavigationProvider.ORGANIC_MAPS },
                                        shape = SegmentedButtonDefaults.itemShape(index = 2, count = 3)
                                    ) {
                                        Text("Organic", maxLines = 1)
                                    }
                                }
                            }

                            HorizontalDivider()

                            // Bluetooth reset - Outlined button (action, not setting)
                            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text("Bluetooth", style = MaterialTheme.typography.labelMedium)
                                OutlinedButton(
                                    onClick = { viewModel.resetBle() },
                                    modifier = Modifier.fillMaxWidth()
                                ) {
                                    Icon(
                                        Icons.Default.BluetoothSearching,
                                        contentDescription = null,
                                        modifier = Modifier.size(18.dp)
                                    )
                                    Spacer(modifier = Modifier.width(8.dp))
                                    Text("Reset BLE Connection")
                                }
                                Text(
                                    text = "Reconnect to MySondyGO device",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    }
                    2 -> {
                        // Balloon settings - Station, burst, ascent, descent
                        val burstAltitudeError = burstAltitude.isNotBlank() &&
                            (burstAltitude.toDoubleOrNull() == null || burstAltitude.toDoubleOrNull()!! <= 0)
                        val ascentRateError = ascentRate.isNotBlank() &&
                            (ascentRate.toDoubleOrNull() == null || ascentRate.toDoubleOrNull()!! <= 0)
                        val descentRateError = descentRate.isNotBlank() &&
                            (descentRate.toDoubleOrNull() == null || descentRate.toDoubleOrNull()!! <= 0)

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
                                isError = burstAltitudeError,
                                supportingText = if (burstAltitudeError) {
                                    { Text("Enter a positive number") }
                                } else null,
                                modifier = Modifier.fillMaxWidth()
                            )
                            OutlinedTextField(
                                value = ascentRate,
                                onValueChange = { ascentRate = it },
                                label = { Text("Ascent Rate (m/s)") },
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                                singleLine = true,
                                isError = ascentRateError,
                                supportingText = if (ascentRateError) {
                                    { Text("Enter a positive number") }
                                } else null,
                                modifier = Modifier.fillMaxWidth()
                            )
                            OutlinedTextField(
                                value = descentRate,
                                onValueChange = { descentRate = it },
                                label = { Text("Descent Rate (m/s)") },
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                                singleLine = true,
                                isError = descentRateError,
                                supportingText = if (descentRateError) {
                                    { Text("Enter a positive number") }
                                } else null,
                                modifier = Modifier.fillMaxWidth()
                            )
                        }
                    }
                3 -> {
                    // Device settings - Tune + Advanced (without Sonde tab)
                    DeviceSettingsContentWithoutSonde(viewModel = viewModel)
                }
            }
        }
    }
}

@Composable
private fun FrequencySettingsTab(viewModel: MapViewModel) {
    val radioData by viewModel.radioData.collectAsState(initial = null)
    val connectionState by viewModel.bleConnectionState.collectAsState()

    if (connectionState == com.balloonhunter.app.domain.models.BLEConnectionState.NOT_CONNECTED) {
        Text(
            "MySondyGO not connected",
            color = MaterialTheme.colorScheme.error,
            style = MaterialTheme.typography.bodyLarge
        )
        return
    }

    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        val sondeTypes = listOf("RS41", "M20", "M10", "PILOT", "DFM")

        var selectedType by remember { mutableStateOf(radioData?.probeType ?: "RS41") }
        var freqDigits by remember { mutableStateOf(frequencyToDigits(radioData?.frequency ?: 403.50)) }

        // Update when radioData first arrives
        LaunchedEffect(radioData) {
            radioData?.let {
                if (selectedType == "RS41" && it.probeType != "RS41") {
                    selectedType = it.probeType
                }
                val newDigits = frequencyToDigits(it.frequency)
                if (freqDigits == frequencyToDigits(403.50) && it.frequency != 403.50) {
                    freqDigits = newDigits
                }
            }
        }

        Text("Sonde Type", style = MaterialTheme.typography.labelMedium)
        Row(
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            sondeTypes.forEach { type ->
                androidx.compose.material3.FilterChip(
                    selected = selectedType == type,
                    onClick = { selectedType = type },
                    label = { Text(type, style = MaterialTheme.typography.labelSmall) },
                    modifier = Modifier.weight(1f)
                )
            }
        }

        Spacer(modifier = Modifier.height(8.dp))

        Text("Frequency (MHz)", style = MaterialTheme.typography.labelMedium)

        // Frequency picker - 5 digit wheels
        Row(
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth()
        ) {
            for (i in 0 until 5) {
                if (i == 3) {
                    Text(".", style = MaterialTheme.typography.headlineSmall)
                }
                FrequencyDigitPicker(
                    value = freqDigits[i],
                    onValueChange = { newDigit ->
                        if (isValidFrequencyDigit(newDigit, i, freqDigits)) {
                            freqDigits = freqDigits.toMutableList().also { it[i] = newDigit }
                        }
                    }
                )
            }
            Text(" MHz", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(start = 8.dp))
        }

        Button(
            onClick = {
                viewModel.setFrequency(digitsToFrequency(freqDigits), selectedType)
            },
            modifier = Modifier.fillMaxWidth()
        ) {
            Text("Apply Frequency")
        }
    }
}

@Composable
private fun FrequencyDigitPicker(
    value: Int,
    onValueChange: (Int) -> Unit
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        IconButton(
            onClick = {
                val newVal = if (value >= 9) 0 else value + 1
                onValueChange(newVal)
            }
        ) {
            Icon(Icons.Default.KeyboardArrowUp, contentDescription = "Increase digit")
        }

        Text(
            text = value.toString(),
            style = MaterialTheme.typography.headlineSmall
        )

        IconButton(
            onClick = {
                val newVal = if (value <= 0) 9 else value - 1
                onValueChange(newVal)
            }
        ) {
            Icon(Icons.Default.KeyboardArrowDown, contentDescription = "Decrease digit")
        }
    }
}

private fun frequencyToDigits(frequency: Double): List<Int> {
    val freq = (frequency * 100).toInt()
    return listOf(
        (freq / 10000) % 10,
        (freq / 1000) % 10,
        (freq / 100) % 10,
        (freq / 10) % 10,
        freq % 10
    )
}

private fun digitsToFrequency(digits: List<Int>): Double {
    val whole = digits[0] * 100 + digits[1] * 10 + digits[2]
    val decimal = digits[3] * 10 + digits[4]
    return whole + decimal / 100.0
}

private fun isValidFrequencyDigit(digit: Int, position: Int, allDigits: List<Int>): Boolean {
    return when (position) {
        0 -> digit == 4
        1 -> digit == 0
        2 -> digit in 0..6
        3 -> if (allDigits[2] == 6) digit == 0 else true
        4 -> if (allDigits[2] == 6 && allDigits[3] == 0) digit == 0 else true
        else -> true
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DeviceSettingsContentWithoutSonde(viewModel: MapViewModel) {
    var showAdvancedSettings by remember { mutableStateOf(false) }
    val connectionState by viewModel.bleConnectionState.collectAsState()

    var initialDeviceSettings by remember { mutableStateOf<com.balloonhunter.app.domain.models.SettingsData?>(null) }
    var initialRadioData by remember { mutableStateOf<com.balloonhunter.app.domain.models.RadioChannelData?>(null) }
    var initialDataCaptured by remember { mutableStateOf(false) }
    var afcData by remember { mutableStateOf<com.balloonhunter.app.data.ble.AfcData?>(null) }
    var isLoading by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        viewModel.deviceSettings.collect { settings ->
            if (!initialDataCaptured) {
                initialDeviceSettings = settings
            }
            isLoading = false
        }
    }

    LaunchedEffect(Unit) {
        viewModel.radioData.collect { radio ->
            if (!initialDataCaptured) {
                initialRadioData = radio
                initialDataCaptured = true
            }
        }
    }

    LaunchedEffect(Unit) {
        viewModel.afcData.collect { afc ->
            afcData = afc
        }
    }

    LaunchedEffect(connectionState) {
        if (connectionState != com.balloonhunter.app.domain.models.BLEConnectionState.NOT_CONNECTED) {
            isLoading = true
            viewModel.requestDeviceSettings()
        }
    }

    Column(modifier = Modifier.fillMaxWidth()) {
        if (connectionState == com.balloonhunter.app.domain.models.BLEConnectionState.NOT_CONNECTED) {
            Text(
                "MySondyGO not connected",
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodyLarge
            )
        } else {
            // AFC Tune section (simplified)
            TuneSection(initialDeviceSettings, afcData, viewModel)

            Spacer(modifier = Modifier.height(16.dp))
            HorizontalDivider()
            Spacer(modifier = Modifier.height(8.dp))

            // Advanced settings - collapsible
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("Advanced Settings", style = MaterialTheme.typography.titleSmall)
                IconButton(onClick = { showAdvancedSettings = !showAdvancedSettings }) {
                    Icon(
                        if (showAdvancedSettings) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                        contentDescription = if (showAdvancedSettings) "Collapse" else "Expand"
                    )
                }
            }

            if (showAdvancedSettings) {
                Text(
                    "Use the full Device Settings screen for advanced configuration.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

@Composable
private fun TuneSection(
    initialSettings: com.balloonhunter.app.domain.models.SettingsData?,
    afcData: com.balloonhunter.app.data.ble.AfcData?,
    viewModel: MapViewModel
) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Text("AFC Tune", style = MaterialTheme.typography.labelMedium)

        // Live AFC values
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Text("Current:", style = MaterialTheme.typography.bodySmall)
            Text(
                "${afcData?.currentFrequency ?: 0}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.primary
            )
        }

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Text("Smoothed:", style = MaterialTheme.typography.bodySmall)
            Text(
                "${afcData?.smoothedFrequency ?: 0}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.tertiary
            )
        }

        val initialCorrection = initialSettings?.frequencyCorrection ?: 0
        var freqCorrection by remember { mutableStateOf(initialCorrection.toString()) }

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            OutlinedTextField(
                value = freqCorrection,
                onValueChange = { freqCorrection = it },
                label = { Text("Offset") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.weight(1f),
                singleLine = true
            )
            Button(
                onClick = {
                    afcData?.smoothedFrequency?.let {
                        freqCorrection = it.toString()
                    }
                },
                enabled = afcData != null
            ) {
                Text("Transfer")
            }
        }

        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            OutlinedButton(
                onClick = {
                    freqCorrection = "0"
                    viewModel.setFrequencyCorrection(0)
                },
                modifier = Modifier.weight(1f),
                colors = ButtonDefaults.outlinedButtonColors(
                    contentColor = MaterialTheme.colorScheme.error
                )
            ) {
                Text("Reset")
            }
            Button(
                onClick = {
                    freqCorrection.toIntOrNull()?.let {
                        viewModel.setFrequencyCorrection(it)
                    }
                },
                modifier = Modifier.weight(1f)
            ) {
                Text("Save")
            }
        }
    }
}
