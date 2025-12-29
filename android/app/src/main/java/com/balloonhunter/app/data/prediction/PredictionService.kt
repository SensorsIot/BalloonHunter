package com.balloonhunter.app.data.prediction

import com.balloonhunter.app.domain.models.BalloonPhase
import com.balloonhunter.app.domain.models.GeoPoint
import com.balloonhunter.app.domain.models.PredictionData
import com.balloonhunter.app.domain.models.PositionData
import com.balloonhunter.app.domain.models.UserSettings
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.time.Instant
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter

class PredictionService(private val scope: CoroutineScope) {
    private val cache = PredictionCache(100, 300)
    private val _prediction = MutableStateFlow<PredictionData?>(null)
    val prediction: StateFlow<PredictionData?> = _prediction.asStateFlow()

    private var timerJob: Job? = null

    fun startTimer(
        positionProvider: () -> PositionData?,
        settingsProvider: () -> UserSettings,
        phaseProvider: () -> BalloonPhase,
        adjustedDescentRateProvider: () -> Double?
    ) {
        timerJob?.cancel()
        timerJob = scope.launch(Dispatchers.IO) {
            while (true) {
                val position = positionProvider()
                if (position != null && phaseProvider() != BalloonPhase.LANDED) {
                    requestPrediction(position, settingsProvider(), phaseProvider(), adjustedDescentRateProvider())
                }
                delay(60000)
            }
        }
    }

    fun stopTimer() {
        timerJob?.cancel()
        timerJob = null
    }

    fun clear() {
        _prediction.value = null
    }

    suspend fun requestPrediction(
        position: PositionData,
        settings: UserSettings,
        phase: BalloonPhase,
        adjustedDescentRate: Double?
    ) {
        val key = cacheKey(position)
        cache.get(key)?.let {
            _prediction.value = it
            return
        }

        val ascentRate = settings.ascentRate
        val burstAltitude = if (position.verticalSpeed >= 0) {
            kotlin.math.max(settings.burstAltitude, position.altitude + 100)
        } else {
            position.altitude + 10
        }

        val usedSmoothed = phase == BalloonPhase.DESCENDING_BELOW_10K &&
            adjustedDescentRate != null && adjustedDescentRate != 0.0
        val descentRate = if (usedSmoothed && adjustedDescentRate != null) {
            kotlin.math.abs(adjustedDescentRate)
        } else {
            settings.descentRate
        }

        val url = buildRequestUrl(position, ascentRate, burstAltitude, descentRate)
        val response = fetchJsonObject(url) ?: return
        val parsed = parsePrediction(response, usedSmoothed)
        cache.put(key, parsed)
        _prediction.value = parsed
    }

    private fun buildRequestUrl(
        position: PositionData,
        ascentRate: Double,
        burstAltitude: Double,
        descentRate: Double
    ): URL {
        val launchTime = OffsetDateTime.now().plusSeconds(60)
        val params = mapOf(
            "launch_latitude" to String.format("%.4f", position.latitude),
            "launch_longitude" to String.format("%.4f", position.longitude),
            "launch_datetime" to launchTime.format(DateTimeFormatter.ISO_OFFSET_DATE_TIME),
            "ascent_rate" to ascentRate.toString(),
            "burst_altitude" to burstAltitude.toString(),
            "descent_rate" to descentRate.toString(),
            "launch_altitude" to position.altitude.toString(),
            "profile" to "standard_profile",
            "format" to "json"
        )

        val encoded = params.entries.joinToString("&") { (k, v) ->
            "$k=${URLEncoder.encode(v, "UTF-8") }"
        }

        return URL("https://api.v2.sondehub.org/tawhiri?$encoded")
    }

    private fun parsePrediction(json: JSONObject, usedSmoothed: Boolean): PredictionData {
        // SondeHub API: { "prediction": [ { "stage": "ascent", "trajectory": [...] }, { "stage": "descent", "trajectory": [...] } ] }
        val predictionArray = json.optJSONArray("prediction")
            ?: return PredictionData(null, null, null, null, null, null, null, null, usedSmoothed)

        var ascentTrajectory: JSONArray? = null
        var descentTrajectory: JSONArray? = null
        for (i in 0 until predictionArray.length()) {
            val stage = predictionArray.optJSONObject(i) ?: continue
            when (stage.optString("stage", "").lowercase()) {
                "ascent" -> ascentTrajectory = stage.optJSONArray("trajectory")
                "descent" -> descentTrajectory = stage.optJSONArray("trajectory")
            }
        }

        val path = mutableListOf<GeoPoint>()
        fun addTrajectory(trajectory: JSONArray?) {
            trajectory ?: return
            for (i in 0 until trajectory.length()) {
                val pt = trajectory.optJSONObject(i) ?: continue
                val lat = pt.optDouble("latitude", Double.NaN)
                val lon = pt.optDouble("longitude", Double.NaN)
                if (lat.isFinite() && lon.isFinite()) path.add(GeoPoint(lat, lon))
            }
        }
        addTrajectory(ascentTrajectory)
        addTrajectory(descentTrajectory)

        val burstPoint = ascentTrajectory?.let { arr ->
            if (arr.length() > 0) arr.optJSONObject(arr.length() - 1)?.let { last ->
                val lat = last.optDouble("latitude", Double.NaN)
                val lon = last.optDouble("longitude", Double.NaN)
                if (lat.isFinite() && lon.isFinite()) GeoPoint(lat, lon) else null
            } else null
        }

        var landingPoint: GeoPoint? = null
        var landingInstant: Instant? = null
        var burstAltitude: Double? = null
        descentTrajectory?.let { arr ->
            if (arr.length() > 0) arr.optJSONObject(arr.length() - 1)?.let { last ->
                val lat = last.optDouble("latitude", Double.NaN)
                val lon = last.optDouble("longitude", Double.NaN)
                if (lat.isFinite() && lon.isFinite()) landingPoint = GeoPoint(lat, lon)
                val datetime = last.optString("datetime", "")
                if (datetime.isNotEmpty()) {
                    landingInstant = try {
                        OffsetDateTime.parse(datetime, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant()
                    } catch (_: Exception) { null }
                }
            }
        }
        ascentTrajectory?.let { arr ->
            if (arr.length() > 0) arr.optJSONObject(arr.length() - 1)?.let { last ->
                val alt = last.optDouble("altitude", Double.NaN)
                if (alt.isFinite()) burstAltitude = alt
            }
        }

        val launchPoint = ascentTrajectory?.let { arr ->
            if (arr.length() > 0) arr.optJSONObject(0)?.let { first ->
                val lat = first.optDouble("latitude", Double.NaN)
                val lon = first.optDouble("longitude", Double.NaN)
                if (lat.isFinite() && lon.isFinite()) GeoPoint(lat, lon) else null
            } else null
        }

        return PredictionData(
            path = if (path.isEmpty()) null else path,
            burstPoint = burstPoint,
            landingPoint = landingPoint,
            landingTime = landingInstant,
            launchPoint = launchPoint,
            burstAltitude = burstAltitude,
            flightTime = null,
            metadata = null,
            usedSmoothedDescentRate = usedSmoothed
        )
    }

    private fun fetchJsonObject(url: URL): JSONObject? {
        val connection = url.openConnection() as HttpURLConnection
        connection.connectTimeout = 10000
        connection.readTimeout = 10000
        connection.requestMethod = "GET"
        return try {
            if (connection.responseCode in 200..299) {
                val body = connection.inputStream.bufferedReader().readText()
                JSONObject(body)
            } else {
                null
            }
        } catch (_: Exception) {
            null
        } finally {
            connection.disconnect()
        }
    }

    private fun cacheKey(position: PositionData): String {
        val lat = String.format("%.2f", position.latitude)
        val lon = String.format("%.2f", position.longitude)
        val alt = position.altitude.toInt().toString()
        val bucket = Instant.now().epochSecond / 300
        return "${position.sondeName}|$lat|$lon|$alt|$bucket"
    }
}

private class PredictionCache(private val capacity: Int, private val ttlSeconds: Long) {
    private val map = object : LinkedHashMap<String, CacheEntry>(capacity, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, CacheEntry>?): Boolean {
            return size > capacity
        }
    }

    fun get(key: String): PredictionData? {
        val entry = map[key] ?: return null
        if (Instant.now().epochSecond - entry.timestamp > ttlSeconds) {
            map.remove(key)
            return null
        }
        return entry.data
    }

    fun put(key: String, data: PredictionData) {
        map[key] = CacheEntry(data, Instant.now().epochSecond)
    }

    data class CacheEntry(val data: PredictionData, val timestamp: Long)
}
