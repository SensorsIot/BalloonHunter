package com.balloonhunter.app.data.routing

import android.content.Context
import com.balloonhunter.app.domain.models.GeoPoint
import com.balloonhunter.app.domain.models.RouteData
import com.balloonhunter.app.domain.models.TransportationMode
import com.balloonhunter.app.domain.services.GeoUtils
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.cos
import kotlin.math.sin
import kotlin.random.Random

class RoutingService(private val context: Context) {
    suspend fun calculateRoute(
        origin: GeoPoint,
        destination: GeoPoint,
        mode: TransportationMode
    ): RouteData = withContext(Dispatchers.IO) {
        val key = MapsKeyProvider.getApiKey(context)
        val apiMode = if (mode == TransportationMode.BIKE) "bicycling" else "driving"
        val route = if (!key.isNullOrBlank()) {
            fetchRoute(origin, destination, apiMode, key)
        } else {
            null
        }

        if (route != null) return@withContext route

        val shifted = attemptShiftedRoutes(origin, destination, apiMode, key)
        shifted ?: fallbackStraightLine(origin, destination, mode)
    }

    private fun fallbackStraightLine(
        origin: GeoPoint,
        destination: GeoPoint,
        mode: TransportationMode
    ): RouteData {
        val distance = GeoUtils.haversineMeters(origin, destination)
        val speed = if (mode == TransportationMode.BIKE) 4.2 else 22.0
        val eta = distance / speed
        return RouteData(
            coordinates = listOf(origin, destination),
            distance = distance,
            expectedTravelTime = eta,
            transportType = mode
        )
    }

    private fun attemptShiftedRoutes(
        origin: GeoPoint,
        destination: GeoPoint,
        apiMode: String,
        key: String?
    ): RouteData? {
        if (key.isNullOrBlank()) return null
        repeat(10) {
            val shifted = shiftDestination(destination, 500.0)
            val route = fetchRoute(origin, shifted, apiMode, key)
            if (route != null) return route
        }
        val radii = listOf(300.0, 600.0, 1200.0)
        val angles = (0 until 360 step 45)
        for (radius in radii) {
            for (angle in angles) {
                val shifted = shiftDestination(destination, radius, angle.toDouble())
                val route = fetchRoute(origin, shifted, apiMode, key)
                if (route != null) return route
            }
        }
        return null
    }

    private fun shiftDestination(destination: GeoPoint, meters: Double, angleDeg: Double? = null): GeoPoint {
        val angle = Math.toRadians(angleDeg ?: Random.nextDouble(0.0, 360.0))
        val deltaLat = meters / 111000.0
        val deltaLon = meters / (111000.0 * cos(Math.toRadians(destination.latitude)))
        return GeoPoint(
            destination.latitude + deltaLat * sin(angle),
            destination.longitude + deltaLon * cos(angle)
        )
    }

    private fun fetchRoute(
        origin: GeoPoint,
        destination: GeoPoint,
        apiMode: String,
        key: String
    ): RouteData? {
        val url = URL(
            "https://maps.googleapis.com/maps/api/directions/json?origin=${origin.latitude},${origin.longitude}" +
                "&destination=${destination.latitude},${destination.longitude}&mode=$apiMode&key=$key"
        )
        val connection = url.openConnection() as HttpURLConnection
        connection.connectTimeout = 10000
        connection.readTimeout = 10000
        return try {
            if (connection.responseCode !in 200..299) return null
            val body = connection.inputStream.bufferedReader().readText()
            parseRoute(JSONObject(body), apiMode)
        } catch (_: Exception) {
            null
        } finally {
            connection.disconnect()
        }
    }

    private fun parseRoute(json: JSONObject, apiMode: String): RouteData? {
        val routes = json.optJSONArray("routes") ?: return null
        if (routes.length() == 0) return null
        val route = routes.optJSONObject(0) ?: return null
        val overview = route.optJSONObject("overview_polyline") ?: return null
        val encoded = overview.optString("points")
        if (encoded.isBlank()) return null
        val coordinates = decodePolyline(encoded)
        val legs = route.optJSONArray("legs") ?: return null
        val leg = legs.optJSONObject(0) ?: return null
        val distance = leg.optJSONObject("distance")?.optDouble("value", 0.0) ?: 0.0
        val duration = leg.optJSONObject("duration")?.optDouble("value", 0.0) ?: 0.0
        val mode = if (apiMode == "bicycling") TransportationMode.BIKE else TransportationMode.CAR
        val adjustedDuration = if (mode == TransportationMode.BIKE) duration * 0.7 else duration
        return RouteData(
            coordinates = coordinates,
            distance = distance,
            expectedTravelTime = adjustedDuration,
            transportType = mode
        )
    }

    private fun decodePolyline(encoded: String): List<GeoPoint> {
        val poly = mutableListOf<GeoPoint>()
        var index = 0
        var lat = 0
        var lng = 0

        while (index < encoded.length) {
            var b: Int
            var shift = 0
            var result = 0
            do {
                b = encoded[index++].code - 63
                result = result or (b and 0x1f shl shift)
                shift += 5
            } while (b >= 0x20)
            val dlat = if (result and 1 != 0) (result shr 1).inv() else result shr 1
            lat += dlat

            shift = 0
            result = 0
            do {
                b = encoded[index++].code - 63
                result = result or (b and 0x1f shl shift)
                shift += 5
            } while (b >= 0x20)
            val dlng = if (result and 1 != 0) (result shr 1).inv() else result shr 1
            lng += dlng

            poly.add(GeoPoint(lat / 1E5, lng / 1E5))
        }
        return poly
    }
}

object MapsKeyProvider {
    fun getApiKey(context: Context): String? {
        return try {
            val appInfo = context.packageManager.getApplicationInfo(
                context.packageName,
                android.content.pm.PackageManager.GET_META_DATA
            )
            appInfo.metaData?.getString("com.google.android.geo.API_KEY")
        } catch (_: Exception) {
            null
        }
    }
}
