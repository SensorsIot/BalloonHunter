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
import kotlinx.coroutines.withContext
import android.util.Log
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.time.Instant
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter

private const val TAG = "debugAPRS"

class AprsService(private val scope: CoroutineScope) {
    private val _aprsDataAvailable = MutableStateFlow(false)
    val aprsDataAvailable: StateFlow<Boolean> = _aprsDataAvailable.asStateFlow()

    val positionUpdates = MutableSharedFlow<PositionData>(extraBufferCapacity = 16)
    val radioUpdates = MutableSharedFlow<RadioChannelData>(extraBufferCapacity = 16)

    // Expose current frequency and probe type for frequency mismatch detection
    private val _currentFrequency = MutableStateFlow<Double?>(null)
    val currentFrequency: StateFlow<Double?> = _currentFrequency.asStateFlow()

    private val _currentProbeType = MutableStateFlow<String?>(null)
    val currentProbeType: StateFlow<String?> = _currentProbeType.asStateFlow()

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
        if (pollingJob != null) {
            Log.d(TAG, "startPolling: already polling, ignoring")
            return
        }
        Log.d(TAG, "startPolling: starting polling for station $stationId")
        pollingJob = scope.launch(Dispatchers.IO) {
            while (true) {
                Log.d(TAG, "poll: fetching telemetry...")
                val result = fetchSiteTelemetry()
                if (result != null) {
                    Log.d(TAG, "poll: SUCCESS - sonde=${result.first.sondeName}, lat=${result.first.latitude}, lon=${result.first.longitude}, alt=${result.first.altitude}")
                    _aprsDataAvailable.value = true
                    lastTelemetryTimestamp = result.first.timestamp
                    _currentFrequency.value = result.second.frequency
                    _currentProbeType.value = result.second.probeType
                    positionUpdates.tryEmit(result.first)
                    radioUpdates.tryEmit(result.second)
                } else {
                    Log.d(TAG, "poll: FAILED - no data returned")
                    _aprsDataAvailable.value = false
                }

                val delaySeconds = nextPollDelaySeconds().coerceAtLeast(15)
                Log.d(TAG, "poll: next poll in ${delaySeconds}s")
                delay(delaySeconds.toLong() * 1000)
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
        Log.d(TAG, "fetchSiteTelemetry: GET $url")
        val response = fetchJsonObject(url, 5000)
        if (response == null) {
            Log.d(TAG, "fetchSiteTelemetry: fetchJsonObject returned null")
            return null
        }
        Log.d(TAG, "fetchSiteTelemetry: got JSON with ${response.length()} keys: ${response.keys().asSequence().toList()}")
        val best = selectLatestSonde(response)
        if (best == null) {
            Log.d(TAG, "fetchSiteTelemetry: selectLatestSonde returned null")
            return null
        }
        Log.d(TAG, "fetchSiteTelemetry: selected sonde ${best.optString("serial")}")
        return convertAprs(best)
    }

    private fun selectLatestSonde(sondesObject: JSONObject): JSONObject? {
        Log.d(TAG, "selectLatestSonde: processing ${sondesObject.length()} sondes")
        var best: JSONObject? = null
        var bestTime: Instant? = null
        val keys = sondesObject.keys()
        while (keys.hasNext()) {
            val serial = keys.next()
            val obj = sondesObject.optJSONObject(serial)
            if (obj == null) {
                Log.d(TAG, "selectLatestSonde: $serial - not a JSONObject, skipping")
                continue
            }
            if (isGroundTest(obj)) {
                Log.d(TAG, "selectLatestSonde: $serial - ground test, skipping")
                continue
            }
            val datetimeStr = obj.optString("datetime")
            val timestamp = parseInstant(datetimeStr)
            if (timestamp == null) {
                Log.d(TAG, "selectLatestSonde: $serial - no valid datetime ($datetimeStr), skipping")
                continue
            }
            Log.d(TAG, "selectLatestSonde: $serial - datetime=$timestamp")
            if (bestTime == null || timestamp.isAfter(bestTime)) {
                best = obj
                bestTime = timestamp
                Log.d(TAG, "selectLatestSonde: $serial is now best candidate")
            }
        }
        Log.d(TAG, "selectLatestSonde: returning ${best?.optString("serial") ?: "null"}")
        return best
    }

    private fun isGroundTest(obj: JSONObject): Boolean {
        val serial = obj.optString("serial", "unknown")
        val sondeLat = obj.optDouble("lat", Double.NaN)
        val sondeLon = obj.optDouble("lon", Double.NaN)
        if (!sondeLat.isFinite() || !sondeLon.isFinite()) {
            Log.d(TAG, "isGroundTest: $serial - no valid sonde coords, not ground test")
            return false
        }

        val uploaderPos = obj.opt("uploader_position")
        if (uploaderPos == null) {
            Log.d(TAG, "isGroundTest: $serial - no uploader_position, not ground test")
            return false
        }
        Log.d(TAG, "isGroundTest: $serial - uploader_position type=${uploaderPos.javaClass.simpleName}, value=$uploaderPos")

        val (uploaderLat, uploaderLon) = when (uploaderPos) {
            is String -> {
                val parts = uploaderPos.split(",")
                if (parts.size != 2) {
                    Log.d(TAG, "isGroundTest: $serial - uploader_position string invalid format")
                    return false
                }
                val lat = parts[0].trim().toDoubleOrNull()
                val lon = parts[1].trim().toDoubleOrNull()
                if (lat == null || lon == null) {
                    Log.d(TAG, "isGroundTest: $serial - uploader_position string parse failed")
                    return false
                }
                lat to lon
            }
            is JSONObject -> {
                val lat = uploaderPos.optDouble("lat", Double.NaN)
                val lon = uploaderPos.optDouble("lon", Double.NaN)
                if (!lat.isFinite() || !lon.isFinite()) {
                    Log.d(TAG, "isGroundTest: $serial - uploader_position object has invalid coords")
                    return false
                }
                lat to lon
            }
            else -> {
                Log.d(TAG, "isGroundTest: $serial - uploader_position unknown type")
                return false
            }
        }

        val distance = GeoUtils.haversineMeters(
            com.balloonhunter.app.domain.models.GeoPoint(sondeLat, sondeLon),
            com.balloonhunter.app.domain.models.GeoPoint(uploaderLat, uploaderLon)
        )
        val isGround = distance < 1000
        Log.d(TAG, "isGroundTest: $serial - distance to uploader=${distance}m, isGroundTest=$isGround")
        return isGround
    }

    private fun convertAprs(obj: JSONObject): Pair<PositionData, RadioChannelData>? {
        val serial = obj.optString("serial", "unknown")
        Log.d(TAG, "convertAprs: processing $serial")
        val lat = obj.optDouble("lat", Double.NaN)
        val lon = obj.optDouble("lon", Double.NaN)
        if (!lat.isFinite() || !lon.isFinite() || (lat == 0.0 && lon == 0.0)) {
            Log.d(TAG, "convertAprs: $serial - invalid coords lat=$lat, lon=$lon")
            return null
        }
        val alt = obj.optDouble("alt", 0.0)
        val hSpeed = obj.optDouble("vel_h", 0.0)
        val vSpeed = obj.optDouble("vel_v", 0.0)
        val sondeName = obj.optString("serial", "")
        val datetimeStr = obj.optString("datetime")
        val timestamp = parseInstant(datetimeStr)
        if (timestamp == null) {
            Log.d(TAG, "convertAprs: $serial - failed to parse datetime: $datetimeStr")
            return null
        }
        val apiTime = parseInstant(obj.optString("time_received"))
        Log.d(TAG, "convertAprs: $serial - lat=$lat, lon=$lon, alt=$alt, timestamp=$timestamp")

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

    private fun fetchJsonObject(url: URL, timeoutMs: Int): JSONObject? {
        Log.d(TAG, "fetchJsonObject: connecting to $url (timeout=${timeoutMs}ms)")
        val connection = url.openConnection() as HttpURLConnection
        connection.connectTimeout = timeoutMs
        connection.readTimeout = timeoutMs
        connection.requestMethod = "GET"
        return try {
            val responseCode = connection.responseCode
            Log.d(TAG, "fetchJsonObject: responseCode=$responseCode")
            if (responseCode in 200..299) {
                val body = connection.inputStream.bufferedReader().readText()
                Log.d(TAG, "fetchJsonObject: received ${body.length} chars")
                JSONObject(body)
            } else {
                Log.d(TAG, "fetchJsonObject: non-success response code $responseCode")
                null
            }
        } catch (e: Exception) {
            Log.d(TAG, "fetchJsonObject: exception ${e.javaClass.simpleName}: ${e.message}")
            null
        } finally {
            connection.disconnect()
        }
    }

    suspend fun fetchGapFill(serial: String): List<BalloonTrackPoint> = withContext(Dispatchers.IO) {
        Log.d(TAG, "fetchGapFill: fetching track history for $serial")
        val url = URL("https://api.v2.sondehub.org/sondes/telemetry?serial=$serial&duration=3d")
        val response = fetchJsonObject(url, 30000)
        if (response == null) {
            Log.d(TAG, "fetchGapFill: failed to fetch data for $serial")
            return@withContext emptyList()
        }
        val dedupe = mutableMapOf<Long, BalloonTrackPoint>()

        val serialData = response.optJSONObject(serial)
        if (serialData == null) {
            Log.d(TAG, "fetchGapFill: no data for serial $serial in response")
            return@withContext emptyList()
        }
        Log.d(TAG, "fetchGapFill: got ${serialData.length()} timestamps for $serial")

        val timestamps = serialData.keys()
        while (timestamps.hasNext()) {
            val tsKey = timestamps.next()
            val obj = serialData.optJSONObject(tsKey) ?: continue
            val timestamp = parseInstant(obj.optString("datetime")) ?: continue
            val lat = obj.optDouble("lat", Double.NaN)
            val lon = obj.optDouble("lon", Double.NaN)
            val alt = obj.optDouble("alt", Double.NaN)
            if (!lat.isFinite() || !lon.isFinite() || !alt.isFinite()) continue
            val key = timestamp.epochSecond
            if (dedupe.containsKey(key)) continue
            dedupe[key] = BalloonTrackPoint(
                latitude = lat,
                longitude = lon,
                altitude = alt,
                timestamp = timestamp,
                verticalSpeed = obj.optDouble("vel_v", 0.0),
                horizontalSpeed = obj.optDouble("vel_h", 0.0)
            )
        }
        Log.d(TAG, "fetchGapFill: returning ${dedupe.size} track points for $serial")
        return@withContext dedupe.toSortedMap().values.toList()
    }
}
