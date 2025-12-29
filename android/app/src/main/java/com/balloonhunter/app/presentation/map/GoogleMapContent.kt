package com.balloonhunter.app.presentation.map

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import com.balloonhunter.app.domain.models.BalloonPhase
import com.balloonhunter.app.domain.models.BalloonTrackPoint
import com.balloonhunter.app.domain.models.GeoPoint
import com.balloonhunter.app.domain.models.LandingPredictionPoint
import com.balloonhunter.app.domain.models.PositionData
import com.balloonhunter.app.domain.models.PredictionData
import com.balloonhunter.app.domain.models.RouteData
import com.google.android.gms.maps.model.BitmapDescriptorFactory
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.LatLng
import com.google.maps.android.compose.CameraPositionState
import com.google.maps.android.compose.Circle
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapProperties
import com.google.maps.android.compose.MapType
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.Marker
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.Polyline

fun GeoPoint.toLatLng() = LatLng(latitude, longitude)

// Map visualization colors - domain-specific for consistent recognition
private object MapColors {
    val track = Color.Red
    val prediction = Color(0xFF00AAFF) // Cyan-blue
    val route = Color.Green
    val landingHistory = Color(0xFF9C27B0) // Purple
}

@Composable
fun GoogleMapContent(
    modifier: Modifier = Modifier,
    cameraPositionState: CameraPositionState,
    satelliteMode: Boolean,
    headingMode: Boolean,
    locationEnabled: Boolean,
    track: List<BalloonTrackPoint>,
    prediction: PredictionData?,
    balloonPhase: BalloonPhase,
    balloonPosition: PositionData?,
    landing: LandingPredictionPoint?,
    landingHistory: List<LandingPredictionPoint>,
    route: RouteData?,
    routeVisible: Boolean
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
        // Track polyline
        if (track.isNotEmpty()) {
            Polyline(
                points = track.map { it.point.toLatLng() },
                color = MapColors.track,
                width = 6f
            )
        }

        // Prediction path polyline
        prediction?.path?.let { path ->
            Polyline(
                points = path.map { it.toLatLng() },
                color = MapColors.prediction,
                width = 8f
            )
        }

        // Burst marker - only visible while ascending
        if (balloonPhase == BalloonPhase.ASCENDING) {
            prediction?.burstPoint?.let { burstPoint ->
                Marker(
                    state = remember(burstPoint) { MarkerState(position = burstPoint.toLatLng()) },
                    title = "Burst Point",
                    icon = BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_ORANGE)
                )
            }
        }

        // Route polyline - hidden if user within 100m of balloon
        if (routeVisible) {
            route?.let { routeData ->
                Polyline(
                    points = routeData.coordinates.map { it.toLatLng() },
                    color = MapColors.route,
                    width = 5f
                )
            }
        }

        // Landing history overlay - polyline + dots
        if (landingHistory.size >= 2) {
            Polyline(
                points = landingHistory.map { it.point.toLatLng() },
                color = MapColors.landingHistory,
                width = 3f
            )
        }
        landingHistory.forEach { historyPoint ->
            Circle(
                center = historyPoint.point.toLatLng(),
                radius = 20.0,
                fillColor = MapColors.landingHistory.copy(alpha = 0.7f),
                strokeColor = MapColors.landingHistory,
                strokeWidth = 2f
            )
        }

        // Landing marker (violet)
        landing?.let {
            Marker(
                state = remember(it) { MarkerState(position = it.point.toLatLng()) },
                title = "Landing",
                icon = BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_VIOLET)
            )
        }

        // Balloon marker
        balloonPosition?.let { pos ->
            val balloonHue = when (balloonPhase) {
                BalloonPhase.ASCENDING -> BitmapDescriptorFactory.HUE_GREEN
                BalloonPhase.DESCENDING_ABOVE_10K -> BitmapDescriptorFactory.HUE_ORANGE
                BalloonPhase.DESCENDING_BELOW_10K -> BitmapDescriptorFactory.HUE_RED
                BalloonPhase.LANDED -> BitmapDescriptorFactory.HUE_VIOLET
                BalloonPhase.UNKNOWN -> BitmapDescriptorFactory.HUE_AZURE
            }
            Marker(
                state = remember(pos) { MarkerState(position = pos.point.toLatLng()) },
                title = pos.sondeName.ifBlank { "Balloon" },
                icon = BitmapDescriptorFactory.defaultMarker(balloonHue)
            )
        }
    }
}
