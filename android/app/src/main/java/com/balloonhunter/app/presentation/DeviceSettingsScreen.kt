package com.balloonhunter.app.presentation

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.balloonhunter.app.data.ble.AfcData
import com.balloonhunter.app.domain.models.BLEConnectionState
import com.balloonhunter.app.domain.models.RadioChannelData
import com.balloonhunter.app.domain.models.SettingsData
import com.balloonhunter.app.presentation.components.FrequencyDigitPicker
import com.balloonhunter.app.presentation.components.digitsToFrequency
import com.balloonhunter.app.presentation.components.frequencyToDigits
import com.balloonhunter.app.presentation.components.isValidFrequencyDigit
import com.balloonhunter.app.presentation.state.MapViewModel

/**
 * Device settings content - can be embedded in any container.
 * Displays the device settings tabs directly without wrapping in a dialog.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DeviceSettingsContent(viewModel: MapViewModel) {
    var selectedTab by remember { mutableIntStateOf(0) }
    var showAdvancedSettings by remember { mutableStateOf(false) }
    val tabs = listOf("Sonde", "Tune")

    val connectionState by viewModel.bleConnectionState.collectAsState()

    // Initial values - captured once and never updated
    var initialDeviceSettings by remember { mutableStateOf<SettingsData?>(null) }
    var initialRadioData by remember { mutableStateOf<RadioChannelData?>(null) }
    var initialDataCaptured by remember { mutableStateOf(false) }

    // AFC data CAN update live (for display only)
    var afcData by remember { mutableStateOf<AfcData?>(null) }
    var isLoading by remember { mutableStateOf(false) }

    // Collect device settings - only capture first value
    LaunchedEffect(Unit) {
        viewModel.deviceSettings.collect { settings ->
            if (!initialDataCaptured) {
                initialDeviceSettings = settings
            }
            isLoading = false
        }
    }

    // Collect radio data - only capture first value
    LaunchedEffect(Unit) {
        viewModel.radioData.collect { radio ->
            if (!initialDataCaptured) {
                initialRadioData = radio
                initialDataCaptured = true
            }
        }
    }

    // Collect AFC data - this CAN update live
    LaunchedEffect(Unit) {
        viewModel.afcData.collect { afc ->
            afcData = afc
        }
    }

    // Request settings when content opens
    LaunchedEffect(connectionState) {
        if (connectionState != BLEConnectionState.NOT_CONNECTED) {
            isLoading = true
            viewModel.requestDeviceSettings()
        }
    }

    Column(modifier = Modifier.fillMaxWidth()) {
        if (connectionState == BLEConnectionState.NOT_CONNECTED) {
            Text(
                "MySondyGO not connected",
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodyLarge
            )
        } else if (isLoading && selectedTab > 1) {
            Box(
                modifier = Modifier.fillMaxWidth().padding(32.dp),
                contentAlignment = Alignment.Center
            ) {
                CircularProgressIndicator()
            }
        } else {
            // Main tabs: Sonde and Tune
            TabRow(selectedTabIndex = selectedTab) {
                tabs.forEachIndexed { index, title ->
                    Tab(
                        selected = selectedTab == index,
                        onClick = { selectedTab = index },
                        text = { Text(title) }
                    )
                }
            }

            Spacer(modifier = Modifier.height(8.dp))

            Column(modifier = Modifier.verticalScroll(rememberScrollState())) {
                when (selectedTab) {
                    0 -> SondeTab(initialRadioData, viewModel)
                    1 -> TuneTab(initialDeviceSettings, afcData, viewModel)
                }

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
                    var advancedTab by remember { mutableIntStateOf(0) }
                    val advancedTabs = listOf("Pins", "Battery", "Radio", "Other")

                    ScrollableTabRow(
                        selectedTabIndex = advancedTab,
                        edgePadding = 0.dp
                    ) {
                        advancedTabs.forEachIndexed { index, title ->
                            Tab(
                                selected = advancedTab == index,
                                onClick = { advancedTab = index },
                                text = { Text(title, maxLines = 1, style = MaterialTheme.typography.labelMedium) }
                            )
                        }
                    }

                    Spacer(modifier = Modifier.height(8.dp))

                    when (advancedTab) {
                        0 -> PinsTab(initialDeviceSettings, viewModel)
                        1 -> BatteryTab(initialDeviceSettings, viewModel)
                        2 -> RadioTab(initialDeviceSettings, viewModel)
                        3 -> OtherTab(initialDeviceSettings, initialRadioData, viewModel)
                    }
                }
            }
        }
    }
}

/**
 * Standalone device settings dialog (kept for backward compatibility).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DeviceSettingsScreen(
    viewModel: MapViewModel,
    onDismiss: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Device Settings") },
        text = {
            DeviceSettingsContent(viewModel = viewModel)
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text("Done")
            }
        }
    )
}

@Composable
private fun SondeTab(initialRadioData: RadioChannelData?, viewModel: MapViewModel) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Text("Sonde Type & Frequency", style = MaterialTheme.typography.titleSmall)

        val sondeTypes = listOf("RS41", "M20", "M10", "PILOT", "DFM")

        // Only initialize once, don't reset on radioData updates
        var selectedType by remember { mutableStateOf(initialRadioData?.probeType ?: "RS41") }
        var freqDigits by remember { mutableStateOf(frequencyToDigits(initialRadioData?.frequency ?: 403.50)) }

        Text("Sonde Type", style = MaterialTheme.typography.bodyMedium)
        SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
            sondeTypes.forEachIndexed { index, type ->
                SegmentedButton(
                    selected = selectedType == type,
                    onClick = { selectedType = type },
                    shape = SegmentedButtonDefaults.itemShape(index = index, count = sondeTypes.size)
                ) {
                    Text(type, style = MaterialTheme.typography.labelSmall)
                }
            }
        }

        Spacer(modifier = Modifier.height(8.dp))

        Text("Frequency (MHz)", style = MaterialTheme.typography.bodyMedium)

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

        val currentFreq = digitsToFrequency(freqDigits)
        Text(
            "Current: ${String.format("%.2f", currentFreq)} MHz",
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.fillMaxWidth(),
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(8.dp))

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
private fun TuneTab(initialSettings: SettingsData?, afcData: AfcData?, viewModel: MapViewModel) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Text("AFC Tune", style = MaterialTheme.typography.titleSmall)

        // Live AFC values - these CAN update live
        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                Text("Live AFC Values", style = MaterialTheme.typography.labelMedium)
                Spacer(modifier = Modifier.height(8.dp))

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Text("Current:")
                    Text(
                        "${afcData?.currentFrequency ?: 0}",
                        color = MaterialTheme.colorScheme.primary
                    )
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Text("Smoothed:")
                    Text(
                        "${afcData?.smoothedFrequency ?: 0}",
                        color = MaterialTheme.colorScheme.tertiary
                    )
                }
            }
        }

        val initialCorrection = initialSettings?.frequencyCorrection ?: 0
        var freqCorrection by remember { mutableStateOf(initialCorrection.toString()) }

        // Current offset display
        Card(
            modifier = Modifier.fillMaxWidth()
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                Text("Current Offset", style = MaterialTheme.typography.labelMedium)
                Text(
                    "$initialCorrection",
                    style = MaterialTheme.typography.headlineSmall,
                    modifier = Modifier.fillMaxWidth(),
                    textAlign = TextAlign.Center
                )
            }
        }

        // New value input
        OutlinedTextField(
            value = freqCorrection,
            onValueChange = { freqCorrection = it },
            label = { Text("New Offset") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth()
        )

        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            Button(
                onClick = {
                    afcData?.smoothedFrequency?.let {
                        freqCorrection = it.toString()
                    }
                },
                modifier = Modifier.weight(1f),
                enabled = afcData != null
            ) {
                Text("Transfer")
            }

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
        }

        Button(
            onClick = {
                freqCorrection.toIntOrNull()?.let {
                    viewModel.setFrequencyCorrection(it)
                }
            },
            modifier = Modifier.fillMaxWidth()
        ) {
            Text("Save Offset")
        }
    }
}

@Composable
private fun PinsTab(initialSettings: SettingsData?, viewModel: MapViewModel) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("OLED/LCD Pins", style = MaterialTheme.typography.titleSmall)

        var oledSDA by remember { mutableStateOf(initialSettings?.oledSDA?.toString() ?: "21") }
        var oledSCL by remember { mutableStateOf(initialSettings?.oledSCL?.toString() ?: "22") }
        var oledRST by remember { mutableStateOf(initialSettings?.oledRST?.toString() ?: "16") }
        var ledPin by remember { mutableStateOf(initialSettings?.ledPin?.toString() ?: "0") }
        var buzPin by remember { mutableStateOf(initialSettings?.buzPin?.toString() ?: "0") }

        OutlinedTextField(
            value = oledSDA,
            onValueChange = { oledSDA = it },
            label = { Text("OLED SDA") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth()
        )
        OutlinedTextField(
            value = oledSCL,
            onValueChange = { oledSCL = it },
            label = { Text("OLED SCL") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth()
        )
        OutlinedTextField(
            value = oledRST,
            onValueChange = { oledRST = it },
            label = { Text("OLED RST") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth()
        )
        OutlinedTextField(
            value = ledPin,
            onValueChange = { ledPin = it },
            label = { Text("LED Pin (0=off)") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth()
        )
        OutlinedTextField(
            value = buzPin,
            onValueChange = { buzPin = it },
            label = { Text("Buzzer Pin (0=off)") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth()
        )

        Button(
            onClick = {
                viewModel.setOLEDPins(
                    oledSDA.toIntOrNull() ?: 21,
                    oledSCL.toIntOrNull() ?: 22,
                    oledRST.toIntOrNull() ?: 16
                )
                viewModel.setLEDPin(ledPin.toIntOrNull() ?: 0)
                viewModel.setBuzzerPin(buzPin.toIntOrNull() ?: 0)
            },
            modifier = Modifier.fillMaxWidth()
        ) {
            Text("Apply Pins")
        }

        Text("Note: Pin changes require reboot", style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
private fun BatteryTab(initialSettings: SettingsData?, viewModel: MapViewModel) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Battery Settings", style = MaterialTheme.typography.titleSmall)

        var batPin by remember { mutableStateOf(initialSettings?.batPin?.toString() ?: "0") }
        var batMin by remember { mutableStateOf(initialSettings?.batMin?.toString() ?: "3000") }
        var batMax by remember { mutableStateOf(initialSettings?.batMax?.toString() ?: "4200") }
        var batType by remember { mutableIntStateOf(initialSettings?.batType ?: 0) }

        OutlinedTextField(
            value = batPin,
            onValueChange = { batPin = it },
            label = { Text("Battery Pin (0=no battery)") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth()
        )
        OutlinedTextField(
            value = batMin,
            onValueChange = { batMin = it },
            label = { Text("Min Voltage (mV)") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth()
        )
        OutlinedTextField(
            value = batMax,
            onValueChange = { batMax = it },
            label = { Text("Max Voltage (mV)") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth()
        )

        Text("Discharge Type", style = MaterialTheme.typography.bodyMedium)
        SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
            SegmentedButton(
                selected = batType == 0,
                onClick = { batType = 0 },
                shape = SegmentedButtonDefaults.itemShape(index = 0, count = 3)
            ) { Text("Linear") }
            SegmentedButton(
                selected = batType == 1,
                onClick = { batType = 1 },
                shape = SegmentedButtonDefaults.itemShape(index = 1, count = 3)
            ) { Text("Sigmoidal") }
            SegmentedButton(
                selected = batType == 2,
                onClick = { batType = 2 },
                shape = SegmentedButtonDefaults.itemShape(index = 2, count = 3)
            ) { Text("Asigmoidal") }
        }

        Button(
            onClick = {
                viewModel.setBatterySettings(
                    batPin.toIntOrNull() ?: 0,
                    batMin.toIntOrNull() ?: 3000,
                    batMax.toIntOrNull() ?: 4200,
                    batType
                )
            },
            modifier = Modifier.fillMaxWidth()
        ) {
            Text("Apply Battery")
        }
    }
}

@Composable
private fun RadioTab(initialSettings: SettingsData?, viewModel: MapViewModel) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Radio Settings", style = MaterialTheme.typography.titleSmall)

        var callSign by remember { mutableStateOf(initialSettings?.callSign ?: "") }
        var rs41Bw by remember { mutableStateOf(initialSettings?.RS41Bandwidth?.toString() ?: "12") }
        var m20Bw by remember { mutableStateOf(initialSettings?.M20Bandwidth?.toString() ?: "12") }
        var m10Bw by remember { mutableStateOf(initialSettings?.M10Bandwidth?.toString() ?: "12") }
        var pilotBw by remember { mutableStateOf(initialSettings?.PILOTBandwidth?.toString() ?: "12") }
        var dfmBw by remember { mutableStateOf(initialSettings?.DFMBandwidth?.toString() ?: "12") }

        OutlinedTextField(
            value = callSign,
            onValueChange = { if (it.length <= 8) callSign = it },
            label = { Text("Call Sign (max 8 chars)") },
            modifier = Modifier.fillMaxWidth()
        )

        Text("RX Bandwidth", style = MaterialTheme.typography.bodyMedium)

        OutlinedTextField(
            value = rs41Bw,
            onValueChange = { rs41Bw = it },
            label = { Text("RS41") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth()
        )
        OutlinedTextField(
            value = m20Bw,
            onValueChange = { m20Bw = it },
            label = { Text("M20") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth()
        )
        OutlinedTextField(
            value = m10Bw,
            onValueChange = { m10Bw = it },
            label = { Text("M10") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth()
        )
        OutlinedTextField(
            value = pilotBw,
            onValueChange = { pilotBw = it },
            label = { Text("PILOT") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth()
        )
        OutlinedTextField(
            value = dfmBw,
            onValueChange = { dfmBw = it },
            label = { Text("DFM") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth()
        )

        Button(
            onClick = {
                viewModel.setCallSign(callSign)
                viewModel.setRXBandwidth(
                    rs41Bw.toIntOrNull(),
                    m20Bw.toIntOrNull(),
                    m10Bw.toIntOrNull(),
                    pilotBw.toIntOrNull(),
                    dfmBw.toIntOrNull()
                )
            },
            modifier = Modifier.fillMaxWidth()
        ) {
            Text("Apply Radio")
        }
    }
}

@Composable
private fun OtherTab(initialSettings: SettingsData?, initialRadioData: RadioChannelData?, viewModel: MapViewModel) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Other Settings", style = MaterialTheme.typography.titleSmall)

        // Mute/Beeper toggle - initialize once
        var isMuted by remember { mutableStateOf(initialRadioData?.buzmute ?: false) }

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("Beeper")
            Switch(
                checked = !isMuted,
                onCheckedChange = { enabled ->
                    isMuted = !enabled
                    viewModel.setMute(!enabled)
                }
            )
        }

        HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))

        var lcdType by remember { mutableIntStateOf(initialSettings?.lcdType ?: 0) }
        var nameType by remember { mutableIntStateOf(initialSettings?.nameType ?: 0) }

        Text("LCD Driver", style = MaterialTheme.typography.bodyMedium)
        SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
            SegmentedButton(
                selected = lcdType == 0,
                onClick = { lcdType = 0 },
                shape = SegmentedButtonDefaults.itemShape(index = 0, count = 2)
            ) { Text("SSD1306") }
            SegmentedButton(
                selected = lcdType == 1,
                onClick = { lcdType = 1 },
                shape = SegmentedButtonDefaults.itemShape(index = 1, count = 2)
            ) { Text("SH1106") }
        }

        Spacer(modifier = Modifier.height(8.dp))

        Text("Name Display", style = MaterialTheme.typography.bodyMedium)
        SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
            SegmentedButton(
                selected = nameType == 0,
                onClick = { nameType = 0 },
                shape = SegmentedButtonDefaults.itemShape(index = 0, count = 2)
            ) { Text("Serial") }
            SegmentedButton(
                selected = nameType == 1,
                onClick = { nameType = 1 },
                shape = SegmentedButtonDefaults.itemShape(index = 1, count = 2)
            ) { Text("APRS Name") }
        }

        Button(
            onClick = {
                viewModel.setLCDDriver(lcdType)
                viewModel.setNameType(nameType)
            },
            modifier = Modifier.fillMaxWidth()
        ) {
            Text("Apply Other")
        }

        Text("Note: LCD changes require reboot", style = MaterialTheme.typography.bodySmall)
    }
}
