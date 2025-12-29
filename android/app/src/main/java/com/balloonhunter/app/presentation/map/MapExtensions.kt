package com.balloonhunter.app.presentation.map

import com.balloonhunter.app.domain.models.GeoPoint
import com.google.android.gms.maps.model.LatLng
import org.osmdroid.util.GeoPoint as OsmGeoPoint

/**
 * Extension functions for converting domain GeoPoint to map-specific coordinate types.
 */

fun GeoPoint.toLatLng() = LatLng(latitude, longitude)

fun GeoPoint.toOsmGeoPoint() = OsmGeoPoint(latitude, longitude)
