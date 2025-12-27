package com.balloonhunter.app.di

import android.content.Context
import androidx.room.Room
import com.balloonhunter.app.data.LocationService
import com.balloonhunter.app.data.aprs.AprsService
import com.balloonhunter.app.data.ble.BleService
import com.balloonhunter.app.data.notifications.NotificationHelper
import com.balloonhunter.app.data.persistence.AppDatabase
import com.balloonhunter.app.data.persistence.LandingHistoryRepository
import com.balloonhunter.app.data.persistence.TelemetryLogger
import com.balloonhunter.app.data.persistence.TrackRepository
import com.balloonhunter.app.data.persistence.UserSettingsStore
import com.balloonhunter.app.data.routing.RoutingService
import com.balloonhunter.app.domain.services.BalloonCoordinator
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object AppModule {
    @Provides
    @Singleton
    @AppScope
    fun provideAppScope(): CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @Provides
    @Singleton
    fun provideDatabase(@ApplicationContext context: Context): AppDatabase {
        return Room.databaseBuilder(context, AppDatabase::class.java, "balloonhunter.db").build()
    }

    @Provides
    fun provideTrackRepository(db: AppDatabase): TrackRepository = TrackRepository(db.trackPointDao())

    @Provides
    fun provideLandingRepository(db: AppDatabase): LandingHistoryRepository = LandingHistoryRepository(db.landingPointDao())

    @Provides
    @Singleton
    fun provideUserSettingsStore(
        @ApplicationContext context: Context,
        @AppScope scope: CoroutineScope
    ): UserSettingsStore = UserSettingsStore(context, scope)

    @Provides
    @Singleton
    fun provideBleService(
        @ApplicationContext context: Context,
        @AppScope scope: CoroutineScope
    ): BleService = BleService(context, scope)

    @Provides
    @Singleton
    fun provideAprsService(@AppScope scope: CoroutineScope): AprsService = AprsService(scope)

    @Provides
    @Singleton
    fun provideLocationService(@ApplicationContext context: Context): LocationService = LocationService(context)

    @Provides
    @Singleton
    fun provideRoutingService(@ApplicationContext context: Context): RoutingService = RoutingService(context)

    @Provides
    @Singleton
    fun provideNotificationHelper(@ApplicationContext context: Context): NotificationHelper = NotificationHelper(context)

    @Provides
    @Singleton
    fun provideTelemetryLogger(@ApplicationContext context: Context): TelemetryLogger = TelemetryLogger(context)

    @Provides
    @Singleton
    fun provideCoordinator(
        @AppScope scope: CoroutineScope,
        bleService: BleService,
        aprsService: AprsService,
        trackRepository: TrackRepository,
        landingHistoryRepository: LandingHistoryRepository,
        settingsStore: UserSettingsStore,
        locationService: LocationService,
        routingService: RoutingService,
        notificationHelper: NotificationHelper,
        telemetryLogger: TelemetryLogger
    ): BalloonCoordinator {
        return BalloonCoordinator(
            scope = scope,
            bleService = bleService,
            aprsService = aprsService,
            trackRepository = trackRepository,
            landingHistoryRepository = landingHistoryRepository,
            settingsStore = settingsStore,
            locationService = locationService,
            routingService = routingService,
            notificationSink = notificationHelper,
            telemetryLogger = telemetryLogger,
            notificationHelper = notificationHelper
        )
    }
}
