package com.balloonhunter.app.presentation

import com.balloonhunter.app.domain.models.GeoPoint
import com.google.android.gms.maps.model.LatLng

fun GeoPoint.toLatLng(): LatLng = LatLng(latitude, longitude)
