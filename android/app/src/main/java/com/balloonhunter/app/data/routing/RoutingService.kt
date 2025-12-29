package com.balloonhunter.app.data.routing

import android.content.Context
import android.util.Log
import android.util.LruCache
import com.balloonhunter.app.domain.models.GeoPoint
import com.balloonhunter.app.domain.models.MapProvider
import com.balloonhunter.app.domain.models.RouteData
import com.balloonhunter.app.domain.models.TransportationMode
import com.balloonhunter.app.domain.services.GeoUtils
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.time.Instant
import kotlin.math.cos
import kotlin.math.sin
import kotlin.random.Random

private const val TAG = "RoutingService"

private data class CacheKey(
    val originLat: Double,
    val originLon: Double,
    val destLat: Double,
    val destLon: Double,
    val mode: TransportationMode,
    val mapProvider: MapProvider
) {
    companion object {
        fun create(origin: GeoPoint, dest: GeoPoint, mode: TransportationMode, mapProvider: MapProvider): CacheKey {
            return CacheKey(
                originLat = (origin.latitude * 1000).toLong() / 1000.0,
                originLon = (origin.longitude * 1000).toLong() / 1000.0,
                destLat = (dest.latitude * 1000).toLong() / 1000.0,
                destLon = (dest.longitude * 1000).toLong() / 1000.0,
                mode = mode,
                mapProvider = mapProvider
            )
        }
    }
}

private data class CachedRoute(
    val route: RouteData,
    val timestamp: Instant
)

class RoutingService(private val context: Context) {
    companion object {
        private const val CACHE_SIZE = 20
        private const val CACHE_TTL_SECONDS = 300L // 5 minutes
        private const val OSRM_BASE_URL = "https://router.project-osrm.org/route/v1"
    }

    private val routeCache = LruCache<CacheKey, CachedRoute>(CACHE_SIZE)

    suspend fun calculateRoute(
        origin: GeoPoint,
        destination: GeoPoint,
        mode: TransportationMode,
        mapProvider: MapProvider = MapProvider.OSM
    ): RouteData = withContext(Dispatchers.IO) {
        val cacheKey = CacheKey.create(origin, destination, mode, mapProvider)
        val cached = routeCache.get(cacheKey)
        if (cached != null) {
            val age = java.time.Duration.between(cached.timestamp, Instant.now()).seconds
            if (age < CACHE_TTL_SECONDS) {
                Log.d(TAG, "Cache hit for route")
                return@withContext cached.route
            }
            routeCache.remove(cacheKey)
        }

        Log.d(TAG, "calculateRoute: provider=$mapProvider mode=$mode origin=$origin dest=$destination")
        val route = when (mapProvider) {
            MapProvider.OSM -> calculateOsrmRoute(origin, destination, mode)
            MapProvider.GOOGLE_MAPS -> calculateGoogleRoute(origin, destination, mode)
        }
        Log.d(TAG, "calculateRoute: route result = ${route?.let { "distance=${it.distance}m, eta=${it.expectedTravelTime}s, points=${it.coordinates.size}" } ?: "NULL"}")

        if (route != null) {
            routeCache.put(cacheKey, CachedRoute(route, Instant.now()))
            return@withContext route
        }

        Log.d(TAG, "Falling back to straight line for mode=$mode")
        fallbackStraightLine(origin, destination, mode)
    }

    private fun calculateOsrmRoute(
        origin: GeoPoint,
        destination: GeoPoint,
        mode: TransportationMode
    ): RouteData? {
        // OSRM public server only supports car routing reliably
        val profile = "driving"
        val coordinates = "${origin.longitude},${origin.latitude};${destination.longitude},${destination.latitude}"
        val url = URL("$OSRM_BASE_URL/$profile/$coordinates?overview=full&geometries=geojson")

        Log.d(TAG, "OSRM request: mode=$mode profile=$profile url=$url")

        val connection = url.openConnection() as HttpURLConnection
        connection.connectTimeout = 10000
        connection.readTimeout = 10000
        connection.setRequestProperty("User-Agent", "BalloonHunter/1.0")

        return try {
            val responseCode = connection.responseCode
            if (responseCode !in 200..299) {
                Log.w(TAG, "OSRM error: $responseCode for profile=$profile")
                return null
            }
            val body = connection.inputStream.bufferedReader().readText()
            Log.d(TAG, "OSRM response for profile=$profile: ${body.take(200)}...")
            parseOsrmRoute(JSONObject(body), mode)
        } catch (e: Exception) {
            Log.e(TAG, "OSRM exception for profile=$profile: ${e.message}")
            null
        } finally {
            connection.disconnect()
        }
    }

    private fun parseOsrmRoute(json: JSONObject, mode: TransportationMode): RouteData? {
        val code = json.optString("code")
        if (code != "Ok") {
            Log.w(TAG, "OSRM response code: $code")
            return null
        }

        val routes = json.optJSONArray("routes") ?: return null
        if (routes.length() == 0) return null

        val route = routes.optJSONObject(0) ?: return null
        val geometry = route.optJSONObject("geometry") ?: return null
        val coordinatesArray = geometry.optJSONArray("coordinates") ?: return null

        val coordinates = mutableListOf<GeoPoint>()
        for (i in 0 until coordinatesArray.length()) {
            val coord = coordinatesArray.optJSONArray(i) ?: continue
            val lon = coord.optDouble(0)
            val lat = coord.optDouble(1)
            coordinates.add(GeoPoint(lat, lon))
        }

        val distance = route.optDouble("distance", 0.0)
        val duration = route.optDouble("duration", 0.0)

        Log.d(TAG, "OSRM route: ${coordinates.size} points, ${distance.toInt()}m, ${duration.toInt()}s")

        return RouteData(
            coordinates = coordinates,
            distance = distance,
            expectedTravelTime = duration,
            transportType = TransportationMode.CAR  // OSRM only does car routing
        )
    }

    private fun calculateGoogleRoute(
        origin: GeoPoint,
        destination: GeoPoint,
        mode: TransportationMode
    ): RouteData? {
        val key = MapsKeyProvider.getApiKey(context)
        val apiMode = if (mode == TransportationMode.BIKE) "bicycling" else "driving"

        val directRoute = if (!key.isNullOrBlank()) {
            fetchGoogleRoute(origin, destination, apiMode, key)
        } else {
            Log.w(TAG, "No Google API key, cannot use Google routing")
            null
        }

        if (directRoute != null) {
            return directRoute
        }

        return attemptShiftedGoogleRoutes(origin, destination, apiMode, key)
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

    private fun attemptShiftedGoogleRoutes(
        origin: GeoPoint,
        destination: GeoPoint,
        apiMode: String,
        key: String?
    ): RouteData? {
        if (key.isNullOrBlank()) return null
        repeat(10) {
            val shifted = shiftDestination(destination, 500.0)
            val route = fetchGoogleRoute(origin, shifted, apiMode, key)
            if (route != null) return route
        }
        val radii = listOf(300.0, 600.0, 1200.0)
        val angles = (0 until 360 step 45)
        for (radius in radii) {
            for (angle in angles) {
                val shifted = shiftDestination(destination, radius, angle.toDouble())
                val route = fetchGoogleRoute(origin, shifted, apiMode, key)
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

    private fun fetchGoogleRoute(
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
            parseGoogleRoute(JSONObject(body), apiMode)
        } catch (_: Exception) {
            null
        } finally {
            connection.disconnect()
        }
    }

    private fun parseGoogleRoute(json: JSONObject, apiMode: String): RouteData? {
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


