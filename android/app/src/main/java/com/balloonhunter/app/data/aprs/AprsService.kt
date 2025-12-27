package com.balloonhunter.app.data.aprs

import com.balloonhunter.app.domain.models.PositionData
import com.balloonhunter.app.domain.models.RadioChannelData
import com.balloonhunter.app.domain.models.TelemetrySource
import com.balloonhunter.app.domain.models.BalloonTrackPoint
import com.balloonhunter.app.domain.services.GeoUtils
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.time.Instant
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter

class AprsService(private val scope: CoroutineScope) {
    private val _aprsDataAvailable = MutableStateFlow(false)
    val aprsDataAvailable: StateFlow<Boolean> = _aprsDataAvailable.asStateFlow()

    val positionUpdates = MutableSharedFlow<PositionData>(extraBufferCapacity = 16)
    val radioUpdates = MutableSharedFlow<RadioChannelData>(extraBufferCapacity = 16)

    private var pollingJob: Job? = null
    private var stationId: String = "06610"
    private var lastTelemetryTimestamp: Instant? = null

    fun setStationId(id: String) {
        if (stationId != id) {
            stationId = id
            restartPolling()
        }
    }

    fun startPolling() {
        if (pollingJob != null) return
        pollingJob = scope.launch(Dispatchers.IO) {
            while (true) {
                val result = fetchSiteTelemetry()
                if (result != null) {
                    _aprsDataAvailable.value = true
                    lastTelemetryTimestamp = result.first.timestamp
                    positionUpdates.tryEmit(result.first)
                    radioUpdates.tryEmit(result.second)
                } else {
                    _aprsDataAvailable.value = false
                }

                delay(nextPollDelaySeconds().coerceAtLeast(15).toLong() * 1000)
            }
        }
    }

    fun stopPolling() {
        pollingJob?.cancel()
        pollingJob = null
    }

    private fun restartPolling() {
        stopPolling()
        startPolling()
    }

    private fun nextPollDelaySeconds(): Long {
        val last = lastTelemetryTimestamp ?: return 15
        val ageSeconds = Instant.now().epochSecond - last.epochSecond
        return when {
            ageSeconds <= 120 -> 15
            ageSeconds <= 1800 -> 300
            else -> 3600
        }
    }

    private fun fetchSiteTelemetry(): Pair<PositionData, RadioChannelData>? {
        val url = URL("https://api.v2.sondehub.org/sondes/site/$stationId")
        val response = fetchJsonArray(url, 5000) ?: return null
        val best = selectLatestSonde(response) ?: return null
        return convertAprs(best)
    }

    private fun selectLatestSonde(array: JSONArray): JSONObject? {
        var best: JSONObject? = null
        var bestTime: Instant? = null
        for (i in 0 until array.length()) {
            val obj = array.optJSONObject(i) ?: continue
            if (isGroundTest(obj)) continue
            val timestamp = parseInstant(obj.optString("datetime")) ?: continue
            if (bestTime == null || timestamp.isAfter(bestTime)) {
                best = obj
                bestTime = timestamp
            }
        }
        return best
    }

    private fun isGroundTest(obj: JSONObject): Boolean {
        val uploader = obj.optJSONObject("uploader_position") ?: return false
        val sondeLat = obj.optDouble("lat", Double.NaN)
        val sondeLon = obj.optDouble("lon", Double.NaN)
        val uploaderLat = uploader.optDouble("lat", Double.NaN)
        val uploaderLon = uploader.optDouble("lon", Double.NaN)
        if (!sondeLat.isFinite() || !sondeLon.isFinite() || !uploaderLat.isFinite() || !uploaderLon.isFinite()) {
            return false
        }
        val distance = GeoUtils.haversineMeters(
            com.balloonhunter.app.domain.models.GeoPoint(sondeLat, sondeLon),
            com.balloonhunter.app.domain.models.GeoPoint(uploaderLat, uploaderLon)
        )
        return distance < 1000
    }

    private fun convertAprs(obj: JSONObject): Pair<PositionData, RadioChannelData>? {
        val lat = obj.optDouble("lat", Double.NaN)
        val lon = obj.optDouble("lon", Double.NaN)
        if (!lat.isFinite() || !lon.isFinite() || (lat == 0.0 && lon == 0.0)) return null
        val alt = obj.optDouble("alt", 0.0)
        val hSpeed = obj.optDouble("vel_h", 0.0)
        val vSpeed = obj.optDouble("vel_v", 0.0)
        val sondeName = obj.optString("serial", "")
        val timestamp = parseInstant(obj.optString("datetime")) ?: return null
        val apiTime = parseInstant(obj.optString("time_received"))

        val freq = when {
            obj.has("tx_frequency") -> obj.optDouble("tx_frequency", 0.0)
            obj.has("frequency") -> obj.optDouble("frequency", 0.0)
            else -> 0.0
        }

        val position = PositionData(
            sondeName = sondeName,
            latitude = lat,
            longitude = lon,
            altitude = alt,
            verticalSpeed = vSpeed,
            horizontalSpeed = hSpeed,
            heading = 0.0,
            temperature = obj.optDouble("temp", 0.0),
            humidity = obj.optDouble("humidity", 0.0),
            pressure = obj.optDouble("pressure", 0.0),
            timestamp = timestamp,
            apiCallTimestamp = apiTime,
            burstKillerTime = 0,
            telemetrySource = TelemetrySource.APRS
        )

        val radio = RadioChannelData(
            sondeName = sondeName,
            timestamp = timestamp,
            telemetrySource = TelemetrySource.APRS,
            probeType = obj.optString("type", ""),
            frequency = String.format("%.2f", freq).toDouble(),
            softwareVersion = "APRS",
            batteryVoltage = 0.0,
            batteryPercentage = 0,
            signalStrength = 0,
            buzmute = false,
            afcFrequency = 0,
            burstKillerEnabled = false,
            burstKillerTime = 0
        )

        return position to radio
    }

    private fun parseInstant(value: String?): Instant? {
        if (value.isNullOrBlank()) return null
        return try {
            OffsetDateTime.parse(value, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant()
        } catch (ex: Exception) {
            try {
                Instant.parse(value)
            } catch (inner: Exception) {
                null
            }
        }
    }

    private fun fetchJsonArray(url: URL, timeoutMs: Int): JSONArray? {
        val connection = url.openConnection() as HttpURLConnection
        connection.connectTimeout = timeoutMs
        connection.readTimeout = timeoutMs
        connection.requestMethod = "GET"
        return try {
            if (connection.responseCode in 200..299) {
                val body = connection.inputStream.bufferedReader().readText()
                JSONArray(body)
            } else {
                null
            }
        } catch (_: Exception) {
            null
        } finally {
            connection.disconnect()
        }
    }

    suspend fun fetchGapFill(serial: String): List<BalloonTrackPoint> = withContextIO {
        val url = URL(\"https://api.v2.sondehub.org/sondes/telemetry?serial=$serial&duration=3d\")
        val array = fetchJsonArray(url, 30000) ?: return@withContextIO emptyList()
        val dedupe = mutableMapOf<Long, BalloonTrackPoint>()
        for (i in 0 until array.length()) {
            val obj = array.optJSONObject(i) ?: continue
            val timestamp = parseInstant(obj.optString(\"datetime\")) ?: continue
            val lat = obj.optDouble(\"lat\", Double.NaN)
            val lon = obj.optDouble(\"lon\", Double.NaN)
            val alt = obj.optDouble(\"alt\", Double.NaN)
            if (!lat.isFinite() || !lon.isFinite() || !alt.isFinite()) continue
            val key = timestamp.epochSecond
            if (dedupe.containsKey(key)) continue
            dedupe[key] = BalloonTrackPoint(
                latitude = lat,
                longitude = lon,
                altitude = alt,
                timestamp = timestamp,
                verticalSpeed = obj.optDouble(\"vel_v\", 0.0),
                horizontalSpeed = obj.optDouble(\"vel_h\", 0.0)
            )
        }
        return@withContextIO dedupe.toSortedMap().values.toList()
    }

    private suspend fun <T> withContextIO(block: suspend () -> T): T {
        return kotlinx.coroutines.withContext(Dispatchers.IO) { block() }
    }
}
