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
import com.balloonhunter.app.domain.models.MapAnnotationItem
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
    val burst = AndroidColor.parseColor("#FF9800") // Orange
}

/**
 * OpenStreetMap content driven by MapAnnotationItem list.
 * All overlay logic is handled by the ViewModel - this composable only renders.
 */
@Composable
fun OsmMapContent(
    modifier: Modifier = Modifier,
    centerLat: Double,
    centerLon: Double,
    zoom: Double,
    satelliteMode: Boolean,
    headingMode: Boolean,
    compassHeading: Float,
    userLat: Double?,
    userLon: Double?,
    annotations: List<MapAnnotationItem>,
    fitAllTrigger: Int = 0
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

    // Handle fit all trigger - zoom to show all overlays from annotations
    LaunchedEffect(fitAllTrigger) {
        if (fitAllTrigger == 0) return@LaunchedEffect

        Log.d(TAG, "Fit all triggered")

        // Collect all points from annotations
        val allPoints = mutableListOf<OsmGeoPoint>()
        annotations.forEach { item ->
            when (item) {
                is MapAnnotationItem.TrackPolyline -> item.points.forEach { allPoints.add(it.toOsmGeoPoint()) }
                is MapAnnotationItem.PredictionPolyline -> item.points.forEach { allPoints.add(it.toOsmGeoPoint()) }
                is MapAnnotationItem.RoutePolyline -> item.points.forEach { allPoints.add(it.toOsmGeoPoint()) }
                is MapAnnotationItem.LandingHistoryPolyline -> item.points.forEach { allPoints.add(it.toOsmGeoPoint()) }
                is MapAnnotationItem.BalloonMarker -> allPoints.add(item.position.toOsmGeoPoint())
                is MapAnnotationItem.LandingMarker -> allPoints.add(item.position.toOsmGeoPoint())
                is MapAnnotationItem.BurstMarker -> allPoints.add(item.position.toOsmGeoPoint())
                is MapAnnotationItem.LandingHistoryDot -> allPoints.add(item.position.toOsmGeoPoint())
            }
        }

        if (allPoints.size >= 2) {
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

    // Save zoom level before entering heading mode to restore when exiting
    var savedZoomBeforeHeading by remember { mutableStateOf(10.0) }

    // Save zoom when entering heading mode
    LaunchedEffect(headingMode) {
        if (headingMode) {
            savedZoomBeforeHeading = mapView.zoomLevelDouble
        }
    }

    // Handle heading mode - rotate map and center on user
    LaunchedEffect(headingMode, compassHeading, userLat, userLon) {
        if (userLat == null || userLon == null) return@LaunchedEffect

        if (headingMode) {
            // In heading mode: rotate map, center on user, preserve zoom
            mapView.mapOrientation = -compassHeading
            mapView.controller.setCenter(OsmGeoPoint(userLat, userLon))
        } else {
            // Exiting heading mode: reset rotation, restore zoom
            mapView.mapOrientation = 0f
            mapView.controller.setZoom(savedZoomBeforeHeading)
        }
        mapView.invalidate()
    }

    // Create a data key from annotations to detect changes
    val dataKey = remember(annotations, satelliteMode) {
        "${annotations.hashCode()}-$satelliteMode"
    }

    var lastProcessedKey by remember { mutableStateOf("") }

    // Render overlays from annotations
    LaunchedEffect(dataKey) {
        if (dataKey == lastProcessedKey) return@LaunchedEffect
        lastProcessedKey = dataKey

        Log.d(TAG, "Annotations changed, updating overlays")

        mapView.overlays.clear()
        mapView.setTileSource(if (satelliteMode) TileSourceFactory.OpenTopo else TileSourceFactory.MAPNIK)

        var balloonPosition: OsmGeoPoint? = null

        annotations.forEach { item ->
            when (item) {
                is MapAnnotationItem.TrackPolyline -> {
                    val line = Polyline().apply {
                        outlinePaint.color = OsmMapColors.track
                        outlinePaint.strokeWidth = 6f
                        setPoints(item.points.map { it.toOsmGeoPoint() })
                    }
                    mapView.overlays.add(line)
                }

                is MapAnnotationItem.PredictionPolyline -> {
                    val line = Polyline().apply {
                        outlinePaint.color = OsmMapColors.prediction
                        outlinePaint.strokeWidth = 8f
                        setPoints(item.points.map { it.toOsmGeoPoint() })
                    }
                    mapView.overlays.add(line)
                }

                is MapAnnotationItem.RoutePolyline -> {
                    val line = Polyline().apply {
                        outlinePaint.color = OsmMapColors.route
                        outlinePaint.strokeWidth = 5f
                        setPoints(item.points.map { it.toOsmGeoPoint() })
                    }
                    mapView.overlays.add(line)
                }

                is MapAnnotationItem.LandingHistoryPolyline -> {
                    val line = Polyline().apply {
                        outlinePaint.color = OsmMapColors.landingHistory
                        outlinePaint.strokeWidth = 3f
                        setPoints(item.points.map { it.toOsmGeoPoint() })
                    }
                    mapView.overlays.add(line)
                }

                is MapAnnotationItem.LandingHistoryDot -> {
                    // OSM doesn't have circles like Google Maps, use small marker
                    val marker = Marker(mapView).apply {
                        position = item.position.toOsmGeoPoint()
                        setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                        alpha = 0.7f
                    }
                    mapView.overlays.add(marker)
                }

                is MapAnnotationItem.BurstMarker -> {
                    val marker = Marker(mapView).apply {
                        position = item.position.toOsmGeoPoint()
                        setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_BOTTOM)
                        title = "Burst Point"
                    }
                    mapView.overlays.add(marker)
                }

                is MapAnnotationItem.LandingMarker -> {
                    val marker = Marker(mapView).apply {
                        position = item.position.toOsmGeoPoint()
                        setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_BOTTOM)
                        title = "Landing"
                    }
                    mapView.overlays.add(marker)
                }

                is MapAnnotationItem.BalloonMarker -> {
                    val marker = Marker(mapView).apply {
                        position = item.position.toOsmGeoPoint()
                        setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_BOTTOM)
                        title = item.title
                        snippet = when (item.phase) {
                            BalloonPhase.ASCENDING -> "Ascending"
                            BalloonPhase.DESCENDING_ABOVE_10K -> ">10km"
                            BalloonPhase.DESCENDING_BELOW_10K -> "<10km"
                            BalloonPhase.LANDED -> "Landed"
                            BalloonPhase.UNKNOWN -> "Unknown"
                        }
                    }
                    mapView.overlays.add(marker)
                    balloonPosition = item.position.toOsmGeoPoint()
                }
            }
        }

        // Center on balloon if present
        balloonPosition?.let { mapView.controller.setCenter(it) }

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
