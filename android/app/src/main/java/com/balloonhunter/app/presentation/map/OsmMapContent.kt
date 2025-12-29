package com.balloonhunter.app.presentation.map

import android.graphics.Color as AndroidColor
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
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
import org.osmdroid.util.GeoPoint as OsmGeoPoint
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.Marker
import org.osmdroid.views.overlay.Polyline

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
    onMapMoved: (lat: Double, lon: Double, zoom: Double) -> Unit
) {
    val context = LocalContext.current

    // Initialize osmdroid configuration BEFORE creating MapView
    val mapView = remember(context) {
        // Must configure before creating MapView
        Configuration.getInstance().apply {
            load(context, context.getSharedPreferences("osmdroid", android.content.Context.MODE_PRIVATE))
            userAgentValue = context.packageName
        }

        MapView(context).apply {
            setTileSource(TileSourceFactory.MAPNIK)
            setMultiTouchControls(true)
            controller.setZoom(zoom)
            controller.setCenter(OsmGeoPoint(centerLat, centerLon))
        }
    }

    // Update map when data changes
    LaunchedEffect(track, prediction, balloonPosition, landing, landingHistory, route, routeVisible, satelliteMode) {
        mapView.overlays.clear()

        // Set tile source based on satellite mode
        if (satelliteMode) {
            // Use OpenTopoMap for a different view (true satellite requires paid services)
            mapView.setTileSource(TileSourceFactory.OpenTopo)
        } else {
            mapView.setTileSource(TileSourceFactory.MAPNIK)
        }

        // Track polyline (red)
        if (track.isNotEmpty()) {
            val trackLine = Polyline().apply {
                outlinePaint.color = AndroidColor.RED
                outlinePaint.strokeWidth = 6f
                setPoints(track.map { it.point.toOsmGeoPoint() })
            }
            mapView.overlays.add(trackLine)
        }

        // Prediction path polyline (cyan-blue)
        prediction?.path?.let { path ->
            if (path.isNotEmpty()) {
                val predictionLine = Polyline().apply {
                    outlinePaint.color = AndroidColor.parseColor("#00AAFF")
                    outlinePaint.strokeWidth = 8f
                    setPoints(path.map { it.toOsmGeoPoint() })
                }
                mapView.overlays.add(predictionLine)
            }
        }

        // Route polyline (green)
        if (routeVisible) {
            route?.let { routeData ->
                if (routeData.coordinates.isNotEmpty()) {
                    val routeLine = Polyline().apply {
                        outlinePaint.color = AndroidColor.GREEN
                        outlinePaint.strokeWidth = 5f
                        setPoints(routeData.coordinates.map { it.toOsmGeoPoint() })
                    }
                    mapView.overlays.add(routeLine)
                }
            }
        }

        // Landing history polyline (purple)
        if (landingHistory.size >= 2) {
            val historyLine = Polyline().apply {
                outlinePaint.color = AndroidColor.parseColor("#9C27B0")
                outlinePaint.strokeWidth = 3f
                setPoints(landingHistory.map { it.point.toOsmGeoPoint() })
            }
            mapView.overlays.add(historyLine)
        }

        // Landing history dots
        landingHistory.forEach { historyPoint ->
            val marker = Marker(mapView).apply {
                position = historyPoint.point.toOsmGeoPoint()
                setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                title = "Landing History"
                // Use default marker icon
            }
            mapView.overlays.add(marker)
        }

        // Burst marker - only while ascending
        if (balloonPhase == BalloonPhase.ASCENDING) {
            prediction?.burstPoint?.let { burstPoint ->
                val marker = Marker(mapView).apply {
                    position = burstPoint.toOsmGeoPoint()
                    setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_BOTTOM)
                    title = "Burst Point"
                }
                mapView.overlays.add(marker)
            }
        }

        // Landing marker (violet)
        landing?.let {
            val marker = Marker(mapView).apply {
                position = it.point.toOsmGeoPoint()
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
                    BalloonPhase.DESCENDING_ABOVE_10K -> "Descending (>10km)"
                    BalloonPhase.DESCENDING_BELOW_10K -> "Descending (<10km)"
                    BalloonPhase.LANDED -> "Landed"
                    BalloonPhase.UNKNOWN -> "Unknown"
                }
            }
            mapView.overlays.add(marker)
        }

        mapView.invalidate()
    }

    // Update center when balloon position changes
    LaunchedEffect(balloonPosition) {
        balloonPosition?.let { pos ->
            mapView.controller.animateTo(pos.point.toOsmGeoPoint())
        }
    }

    AndroidView(
        factory = { mapView },
        modifier = modifier.fillMaxSize(),
        update = { view ->
            // Report map movements back
            view.addOnFirstLayoutListener { _, _, _, _, _ ->
                onMapMoved(
                    view.mapCenter.latitude,
                    view.mapCenter.longitude,
                    view.zoomLevelDouble
                )
            }
        }
    )

    DisposableEffect(mapView) {
        onDispose {
            mapView.onDetach()
        }
    }
}
