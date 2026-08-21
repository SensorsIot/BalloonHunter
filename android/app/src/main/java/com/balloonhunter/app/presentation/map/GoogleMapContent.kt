package com.balloonhunter.app.presentation.map

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import com.balloonhunter.app.domain.models.BalloonPhase
import com.balloonhunter.app.domain.models.MapAnnotationItem
import com.google.android.gms.maps.model.BitmapDescriptorFactory
import com.google.maps.android.compose.CameraPositionState
import com.google.maps.android.compose.Circle
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapProperties
import com.google.maps.android.compose.MapType
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.Marker
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.Polyline

// Map visualization colors - domain-specific for consistent recognition
private object MapColors {
    val track = Color.Red
    val prediction = Color(0xFF00AAFF) // Cyan-blue
    val route = Color.Green
    val landingHistory = Color(0xFF9C27B0) // Purple
}

/**
 * Google Maps content driven by MapAnnotationItem list.
 * All overlay logic is handled by the ViewModel - this composable only renders.
 */
@Composable
fun GoogleMapContent(
    modifier: Modifier = Modifier,
    cameraPositionState: CameraPositionState,
    satelliteMode: Boolean,
    headingMode: Boolean,
    locationEnabled: Boolean,
    annotations: List<MapAnnotationItem>
) {
    GoogleMap(
        modifier = modifier.fillMaxSize(),
        cameraPositionState = cameraPositionState,
        properties = MapProperties(
            mapType = if (satelliteMode) MapType.HYBRID else MapType.NORMAL,
            isMyLocationEnabled = locationEnabled
        ),
        uiSettings = MapUiSettings(
            zoomControlsEnabled = false,
            myLocationButtonEnabled = false,
            scrollGesturesEnabled = !headingMode,
            tiltGesturesEnabled = !headingMode
        )
    ) {
        // Render all annotations from ViewModel
        annotations.forEach { item ->
            when (item) {
                is MapAnnotationItem.TrackPolyline -> {
                    Polyline(
                        points = item.points.map { it.toLatLng() },
                        color = MapColors.track,
                        width = 6f
                    )
                }

                is MapAnnotationItem.PredictionPolyline -> {
                    Polyline(
                        points = item.points.map { it.toLatLng() },
                        color = MapColors.prediction,
                        width = 8f
                    )
                }

                is MapAnnotationItem.RoutePolyline -> {
                    Polyline(
                        points = item.points.map { it.toLatLng() },
                        color = MapColors.route,
                        width = 5f
                    )
                }

                is MapAnnotationItem.LandingHistoryPolyline -> {
                    Polyline(
                        points = item.points.map { it.toLatLng() },
                        color = MapColors.landingHistory,
                        width = 3f
                    )
                }

                is MapAnnotationItem.LandingHistoryDot -> {
                    Circle(
                        center = item.position.toLatLng(),
                        radius = 20.0,
                        fillColor = MapColors.landingHistory.copy(alpha = 0.7f),
                        strokeColor = MapColors.landingHistory,
                        strokeWidth = 2f
                    )
                }

                is MapAnnotationItem.BurstMarker -> {
                    Marker(
                        state = remember(item.position) { MarkerState(position = item.position.toLatLng()) },
                        title = "Burst Point",
                        icon = BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_ORANGE)
                    )
                }

                is MapAnnotationItem.LandingMarker -> {
                    Marker(
                        state = remember(item.position) { MarkerState(position = item.position.toLatLng()) },
                        title = "Landing",
                        icon = BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_VIOLET)
                    )
                }

                is MapAnnotationItem.BalloonMarker -> {
                    val balloonHue = when (item.phase) {
                        BalloonPhase.ASCENDING -> BitmapDescriptorFactory.HUE_GREEN
                        BalloonPhase.DESCENDING_ABOVE_10K -> BitmapDescriptorFactory.HUE_ORANGE
                        BalloonPhase.DESCENDING_BELOW_10K -> BitmapDescriptorFactory.HUE_RED
                        BalloonPhase.LANDED -> BitmapDescriptorFactory.HUE_VIOLET
                        BalloonPhase.UNKNOWN -> BitmapDescriptorFactory.HUE_AZURE
                    }
                    Marker(
                        state = remember(item.position) { MarkerState(position = item.position.toLatLng()) },
                        title = item.title,
                        icon = BitmapDescriptorFactory.defaultMarker(balloonHue)
                    )
                }
            }
        }
    }
}
