package com.balloonhunter.app.presentation.map

import android.content.Context
import android.graphics.Color as AndroidColor
import android.util.Log
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import com.balloonhunter.app.domain.models.BalloonPhase
import com.balloonhunter.app.domain.models.BalloonTrackPoint
import com.balloonhunter.app.domain.models.GeoPoint
import com.balloonhunter.app.domain.models.LandingPredictionPoint
import com.balloonhunter.app.domain.models.PositionData
import com.balloonhunter.app.domain.models.PredictionData
import com.balloonhunter.app.domain.models.RouteData
import org.osmdroid.config.Configuration
import org.osmdroid.tileprovider.tilesource.TileSourceFactory
import org.osmdroid.util.BoundingBox
import org.osmdroid.util.GeoPoint as OsmGeoPoint
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.Marker
import org.osmdroid.views.overlay.Polyline
import java.io.File

private const val TAG = "OsmMapContent"

// Map visualization colors - domain-specific for consistent recognition
private object OsmMapColors {
    val track = AndroidColor.RED
    val prediction = AndroidColor.parseColor("#00AAFF") // Cyan-blue
    val route = AndroidColor.GREEN
    val landingHistory = AndroidColor.parseColor("#9C27B0") // Purple
}

private fun GeoPoint.toOsmGeoPoint() = OsmGeoPoint(latitude, longitude)

@Composable
fun OsmMapContent(
    modifier: Modifier = Modifier,
    centerLat: Double,
    centerLon: Double,
    zoom: Double,
    satelliteMode: Boolean,
    track: List<BalloonTrackPoint>,
    prediction: PredictionData?,
    balloonPhase: BalloonPhase,
    balloonPosition: PositionData?,
    landing: LandingPredictionPoint?,
    landingHistory: List<LandingPredictionPoint>,
    route: RouteData?,
    routeVisible: Boolean,
    fitAllTrigger: Int = 0,
    onMapMoved: (lat: Double, lon: Double, zoom: Double) -> Unit
) {
    val context = LocalContext.current

    // Initialize osmdroid configuration once
    val configInitialized = remember {
        Log.d(TAG, "Initializing osmdroid")
        try {
            Configuration.getInstance().apply {
                load(context, context.getSharedPreferences("osmdroid", Context.MODE_PRIVATE))
                userAgentValue = context.packageName
                osmdroidTileCache = File(context.cacheDir, "osmdroid")
            }
            true
        } catch (e: Exception) {
            Log.e(TAG, "Config error", e)
            false
        }
    }

    if (!configInitialized) return

    // Create MapView once and keep reference
    val mapView = remember {
        Log.d(TAG, "Creating MapView")
        MapView(context).apply {
            setTileSource(TileSourceFactory.MAPNIK)
            setMultiTouchControls(true)
            controller.setZoom(zoom)
            controller.setCenter(OsmGeoPoint(centerLat, centerLon))
        }
    }

    // Handle fit all trigger - zoom to show all overlays
    LaunchedEffect(fitAllTrigger) {
        if (fitAllTrigger == 0) return@LaunchedEffect

        Log.d(TAG, "Fit all triggered")

        // Collect all points
        val allPoints = mutableListOf<OsmGeoPoint>()

        // Track points
        track.forEach { allPoints.add(it.point.toOsmGeoPoint()) }

        // Prediction path
        prediction?.path?.forEach { allPoints.add(it.toOsmGeoPoint()) }

        // Burst point
        prediction?.burstPoint?.let { allPoints.add(it.toOsmGeoPoint()) }

        // Landing
        landing?.let { allPoints.add(it.point.toOsmGeoPoint()) }

        // Landing history
        landingHistory.forEach { allPoints.add(it.point.toOsmGeoPoint()) }

        // Balloon position
        balloonPosition?.let { allPoints.add(it.point.toOsmGeoPoint()) }

        if (allPoints.size >= 2) {
            // Calculate bounding box
            var minLat = Double.MAX_VALUE
            var maxLat = -Double.MAX_VALUE
            var minLon = Double.MAX_VALUE
            var maxLon = -Double.MAX_VALUE

            allPoints.forEach { point ->
                minLat = minOf(minLat, point.latitude)
                maxLat = maxOf(maxLat, point.latitude)
                minLon = minOf(minLon, point.longitude)
                maxLon = maxOf(maxLon, point.longitude)
            }

            // Add padding (about 10%)
            val latPadding = (maxLat - minLat) * 0.1
            val lonPadding = (maxLon - minLon) * 0.1

            val boundingBox = BoundingBox(
                maxLat + latPadding,
                maxLon + lonPadding,
                minLat - latPadding,
                minLon - lonPadding
            )

            mapView.zoomToBoundingBox(boundingBox, true)
            Log.d(TAG, "Zoomed to bounding box with ${allPoints.size} points")
        } else if (allPoints.size == 1) {
            mapView.controller.setCenter(allPoints.first())
            mapView.controller.setZoom(12.0)
        }
    }

    // Create a data key to detect actual changes
    val dataKey = remember(
        track.size,
        track.lastOrNull()?.point,
        prediction?.path?.size,
        balloonPosition?.point,
        balloonPhase,
        landing?.point,
        landingHistory.size,
        routeVisible,
        route?.coordinates?.size,
        route?.transportType,
        route?.coordinates?.firstOrNull(),
        satelliteMode
    ) {
        "${track.size}-${track.lastOrNull()?.point}-${prediction?.path?.size}-${balloonPosition?.point}-$balloonPhase-${landing?.point}-${landingHistory.size}-$routeVisible-${route?.coordinates?.size}-${route?.transportType}-${route?.coordinates?.firstOrNull()}-$satelliteMode"
    }

    // Track the last key we processed
    var lastProcessedKey by remember { mutableStateOf("") }

    // Only update overlays when data actually changes
    LaunchedEffect(dataKey) {
        if (dataKey == lastProcessedKey) return@LaunchedEffect
        lastProcessedKey = dataKey

        Log.d(TAG, "Data changed, updating overlays")

        mapView.overlays.clear()

        // Set tile source
        mapView.setTileSource(
            if (satelliteMode) TileSourceFactory.OpenTopo else TileSourceFactory.MAPNIK
        )

        // Track polyline - data arrives pre-sorted from BalloonTrackService
        if (track.isNotEmpty()) {
            val trackLine = Polyline().apply {
                outlinePaint.color = OsmMapColors.track
                outlinePaint.strokeWidth = 6f
                setPoints(track.map { it.point.toOsmGeoPoint() })
            }
            mapView.overlays.add(trackLine)
        }

        // Prediction path
        prediction?.path?.takeIf { it.isNotEmpty() }?.let { path ->
            val predictionLine = Polyline().apply {
                outlinePaint.color = OsmMapColors.prediction
                outlinePaint.strokeWidth = 8f
                setPoints(path.map { it.toOsmGeoPoint() })
            }
            mapView.overlays.add(predictionLine)
        }

        // Route
        if (routeVisible) {
            route?.coordinates?.takeIf { it.isNotEmpty() }?.let { coords ->
                val routeLine = Polyline().apply {
                    outlinePaint.color = OsmMapColors.route
                    outlinePaint.strokeWidth = 5f
                    setPoints(coords.map { it.toOsmGeoPoint() })
                }
                mapView.overlays.add(routeLine)
            }
        }

        // Landing history polyline
        if (landingHistory.size >= 2) {
            val historyLine = Polyline().apply {
                outlinePaint.color = OsmMapColors.landingHistory
                outlinePaint.strokeWidth = 3f
                setPoints(landingHistory.map { it.point.toOsmGeoPoint() })
            }
            mapView.overlays.add(historyLine)
        }

        // Burst marker
        if (balloonPhase == BalloonPhase.ASCENDING) {
            prediction?.burstPoint?.let { burst ->
                val marker = Marker(mapView).apply {
                    position = burst.toOsmGeoPoint()
                    setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_BOTTOM)
                    title = "Burst"
                }
                mapView.overlays.add(marker)
            }
        }

        // Landing marker
        landing?.let { land ->
            val marker = Marker(mapView).apply {
                position = land.point.toOsmGeoPoint()
                setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_BOTTOM)
                title = "Landing"
            }
            mapView.overlays.add(marker)
        }

        // Balloon marker
        balloonPosition?.let { pos ->
            val marker = Marker(mapView).apply {
                position = pos.point.toOsmGeoPoint()
                setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_BOTTOM)
                title = pos.sondeName.ifBlank { "Balloon" }
                snippet = when (balloonPhase) {
                    BalloonPhase.ASCENDING -> "Ascending"
                    BalloonPhase.DESCENDING_ABOVE_10K -> ">10km"
                    BalloonPhase.DESCENDING_BELOW_10K -> "<10km"
                    BalloonPhase.LANDED -> "Landed"
                    BalloonPhase.UNKNOWN -> "Unknown"
                }
            }
            mapView.overlays.add(marker)
            mapView.controller.setCenter(pos.point.toOsmGeoPoint())
        }

        mapView.invalidate()
        Log.d(TAG, "Overlays: ${mapView.overlays.size}")
    }

    Box(modifier = modifier.clipToBounds()) {
        AndroidView(
            factory = { mapView },
            modifier = Modifier.fillMaxSize()
        )
    }

    DisposableEffect(mapView) {
        onDispose {
            Log.d(TAG, "Disposing MapView")
            mapView.onDetach()
        }
    }
}
