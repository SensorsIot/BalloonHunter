package com.balloonhunter.app.data.notifications

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.app.NotificationCompat
import com.balloonhunter.app.domain.models.LandingPredictionPoint
import com.balloonhunter.app.domain.models.TransportationMode
import com.balloonhunter.app.domain.services.GeoUtils
import com.balloonhunter.app.domain.services.TrackNotificationSink

class NotificationHelper(private val context: Context) : TrackNotificationSink {
    companion object {
        const val CHANNEL_NAV = "nav_updates"
        const val CHANNEL_TRACK = "track_updates"
    }

    private val notificationManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private var lastLandingPoint: LandingPredictionPoint? = null

    init {
        createChannels()
    }

    override fun notifyTrackTruncation(reason: String) {
        val notification = NotificationCompat.Builder(context, CHANNEL_TRACK)
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentTitle("Track truncated")
            .setContentText(reason)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()
        notificationManager.notify(2001, notification)
    }

    fun notifyNavigationUpdate(point: LandingPredictionPoint, mode: TransportationMode) {
        val last = lastLandingPoint
        if (last != null) {
            val distance = GeoUtils.haversineMeters(last.point, point.point)
            if (distance < 300) return
        }
        lastLandingPoint = point

        val uri = Uri.parse("google.navigation:q=${point.latitude},${point.longitude}&mode=${if (mode == TransportationMode.BIKE) "b" else "d"}")
        val intent = Intent(Intent.ACTION_VIEW, uri)
        val pending = PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_IMMUTABLE)

        val notification = NotificationCompat.Builder(context, CHANNEL_NAV)
            .setSmallIcon(android.R.drawable.ic_menu_directions)
            .setContentTitle("Landing updated")
            .setContentText("New destination sent to Maps")
            .setContentIntent(pending)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()

        notificationManager.notify(2002, notification)
    }

    private fun createChannels() {
        val navChannel = NotificationChannel(
            CHANNEL_NAV,
            "Navigation updates",
            NotificationManager.IMPORTANCE_HIGH
        )
        val trackChannel = NotificationChannel(
            CHANNEL_TRACK,
            "Track updates",
            NotificationManager.IMPORTANCE_HIGH
        )
        notificationManager.createNotificationChannel(navChannel)
        notificationManager.createNotificationChannel(trackChannel)
    }
}
