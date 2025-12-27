package com.balloonhunter.app.data.ble

import com.balloonhunter.app.domain.models.PositionData
import com.balloonhunter.app.domain.models.RadioChannelData
import com.balloonhunter.app.domain.models.SettingsData
import com.balloonhunter.app.domain.models.TelemetrySource
import java.time.Instant

sealed class BleParsedResult {
    data class Position(val position: PositionData, val radio: RadioChannelData) : BleParsedResult()
    data class Radio(val radio: RadioChannelData) : BleParsedResult()
    data class Settings(val settings: SettingsData) : BleParsedResult()
    object Invalid : BleParsedResult()
}

class BlePacketParser {
    fun parse(raw: String, now: Instant = Instant.now()): BleParsedResult {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return BleParsedResult.Invalid
        val parts = trimmed.split("/")
        if (parts.isEmpty()) return BleParsedResult.Invalid

        return when (parts[0]) {
            "0" -> parseType0(parts, now)
            "1" -> parseType1(parts, now)
            "2" -> parseType2(parts, now)
            "3" -> parseType3(parts, now)
            else -> BleParsedResult.Invalid
        }
    }

    private fun parseType0(parts: List<String>, now: Instant): BleParsedResult {
        if (parts.size < 8) return BleParsedResult.Invalid
        val probeType = parts[1]
        val frequency = parts[2].toDoubleOrNull() ?: 0.0
        val rssi = normalizeRssi(parts[3].toIntOrNull())
        val batteryPercentage = parts[4].toIntOrNull() ?: 0
        val batteryVoltage = parts[5].toDoubleOrNull() ?: 0.0
        val buzmute = parts[6] == "1"
        val softwareVersion = parts[7]

        val radio = RadioChannelData(
            sondeName = "",
            timestamp = now,
            telemetrySource = TelemetrySource.BLE,
            probeType = probeType,
            frequency = frequency,
            softwareVersion = softwareVersion,
            batteryVoltage = batteryVoltage,
            batteryPercentage = batteryPercentage,
            signalStrength = rssi,
            buzmute = buzmute,
            afcFrequency = 0,
            burstKillerEnabled = false,
            burstKillerTime = 0
        )
        return BleParsedResult.Radio(radio)
    }

    private fun parseType1(parts: List<String>, now: Instant): BleParsedResult {
        if (parts.size < 20) return BleParsedResult.Invalid
        val probeType = parts[1]
        val frequency = parts[2].toDoubleOrNull() ?: 0.0
        val sondeName = parts[3]
        val latitude = parts[4].toDoubleOrNull()
        val longitude = parts[5].toDoubleOrNull()
        val altitude = parts[6].toDoubleOrNull()
        val horizontalSpeed = parts[7].toDoubleOrNull()
        val verticalSpeed = parts[8].toDoubleOrNull()
        val rssi = normalizeRssi(parts[9].toIntOrNull())
        val batteryPercentage = parts[10].toIntOrNull() ?: 0
        val afcFrequency = parts[11].toIntOrNull() ?: 0
        val burstKillerTime = parts.getOrNull(13)?.toIntOrNull() ?: 0
        val batteryVoltage = parts.getOrNull(14)?.toDoubleOrNull() ?: 0.0
        val buzmute = parts.getOrNull(15) == "1"
        val softwareVersion = parts.getOrNull(19) ?: ""

        if (probeType.isEmpty() || frequency <= 0.0 || latitude == null || longitude == null || altitude == null) {
            return BleParsedResult.Invalid
        }
        if (!latitude.isFinite() || !longitude.isFinite() || latitude == 0.0 && longitude == 0.0) {
            return BleParsedResult.Invalid
        }

        val position = PositionData(
            sondeName = sondeName,
            latitude = latitude,
            longitude = longitude,
            altitude = altitude,
            verticalSpeed = verticalSpeed ?: 0.0,
            horizontalSpeed = horizontalSpeed ?: 0.0,
            heading = 0.0,
            temperature = 0.0,
            humidity = 0.0,
            pressure = 0.0,
            timestamp = now,
            apiCallTimestamp = null,
            burstKillerTime = burstKillerTime,
            telemetrySource = TelemetrySource.BLE
        )

        val radio = RadioChannelData(
            sondeName = sondeName,
            timestamp = now,
            telemetrySource = TelemetrySource.BLE,
            probeType = probeType,
            frequency = frequency,
            softwareVersion = softwareVersion,
            batteryVoltage = batteryVoltage,
            batteryPercentage = batteryPercentage,
            signalStrength = rssi,
            buzmute = buzmute,
            afcFrequency = afcFrequency,
            burstKillerEnabled = parts.getOrNull(12) == "1",
            burstKillerTime = burstKillerTime
        )

        return BleParsedResult.Position(position, radio)
    }

    private fun parseType2(parts: List<String>, now: Instant): BleParsedResult {
        if (parts.size < 10) return BleParsedResult.Invalid
        val probeType = parts[1]
        val frequency = parts[2].toDoubleOrNull() ?: 0.0
        val sondeName = parts[3]
        val rssi = normalizeRssi(parts[4].toIntOrNull())
        val batteryPercentage = parts[5].toIntOrNull() ?: 0
        val afcFrequency = parts[6].toIntOrNull() ?: 0
        val batteryVoltage = parts[7].toDoubleOrNull() ?: 0.0
        val buzmute = parts[8] == "1"
        val softwareVersion = parts[9]

        val radio = RadioChannelData(
            sondeName = sondeName,
            timestamp = now,
            telemetrySource = TelemetrySource.BLE,
            probeType = probeType,
            frequency = frequency,
            softwareVersion = softwareVersion,
            batteryVoltage = batteryVoltage,
            batteryPercentage = batteryPercentage,
            signalStrength = rssi,
            buzmute = buzmute,
            afcFrequency = afcFrequency,
            burstKillerEnabled = false,
            burstKillerTime = 0
        )
        return BleParsedResult.Radio(radio)
    }

    private fun parseType3(parts: List<String>, now: Instant): BleParsedResult {
        if (parts.size < 22) return BleParsedResult.Invalid
        val settings = SettingsData(
            sondeName = "",
            timestamp = now,
            telemetrySource = TelemetrySource.BLE,
            oledSDA = parts[3].toIntOrNull() ?: 0,
            oledSCL = parts[4].toIntOrNull() ?: 0,
            oledRST = parts[5].toIntOrNull() ?: 0,
            ledPin = parts[6].toIntOrNull() ?: 0,
            RS41Bandwidth = parts[7].toIntOrNull() ?: 0,
            M20Bandwidth = parts[8].toIntOrNull() ?: 0,
            M10Bandwidth = parts[9].toIntOrNull() ?: 0,
            PILOTBandwidth = parts[10].toIntOrNull() ?: 0,
            DFMBandwidth = parts[11].toIntOrNull() ?: 0,
            frequencyCorrection = parts[12].toIntOrNull() ?: 0,
            callSign = parts[13],
            batPin = parts[14].toIntOrNull() ?: 0,
            batMin = parts[15].toIntOrNull() ?: 0,
            batMax = parts[16].toIntOrNull() ?: 0,
            batType = parts[17].toIntOrNull() ?: 0,
            lcdType = parts[18].toIntOrNull() ?: 0,
            nameType = parts[19].toIntOrNull() ?: 0,
            buzPin = parts[20].toIntOrNull() ?: 0,
            softwareVersion = parts[21],
            bluetoothStatus = 0,
            lcdStatus = 0,
            serialSpeed = 0,
            serialPort = 0,
            aprsName = 0
        )
        return BleParsedResult.Settings(settings)
    }

    private fun normalizeRssi(value: Int?): Int {
        val rssi = value ?: 0
        return if (rssi > 0) -rssi else rssi
    }
}
