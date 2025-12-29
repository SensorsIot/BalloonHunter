package com.balloonhunter.app.di

import android.content.Context
import androidx.room.Room
import com.balloonhunter.app.data.CompassService
import com.balloonhunter.app.data.LocationService
import com.balloonhunter.app.data.aprs.AprsService
import com.balloonhunter.app.data.ble.BleService
import com.balloonhunter.app.data.notifications.NotificationHelper
import com.balloonhunter.app.data.persistence.AppDatabase
import com.balloonhunter.app.data.persistence.LandingHistoryRepository
import com.balloonhunter.app.data.persistence.TelemetryLogger
import com.balloonhunter.app.data.persistence.TrackRepository
import com.balloonhunter.app.data.persistence.UserSettingsStore
import com.balloonhunter.app.data.prediction.PredictionService
import com.balloonhunter.app.data.routing.RoutingService
import com.balloonhunter.app.domain.services.BalloonCoordinator
import com.balloonhunter.app.domain.services.BalloonPositionService
import com.balloonhunter.app.domain.services.BalloonTrackService
import com.balloonhunter.app.domain.services.LandingPointService
import com.balloonhunter.app.domain.startup.StartupOrchestrator
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
    fun provideCompassService(@ApplicationContext context: Context): CompassService = CompassService(context)

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
    fun provideBalloonPositionService(): BalloonPositionService = BalloonPositionService()

    @Provides
    @Singleton
    fun provideBalloonTrackService(): BalloonTrackService = BalloonTrackService()

    @Provides
    @Singleton
    fun provideLandingPointService(landingHistoryRepository: LandingHistoryRepository): LandingPointService =
        LandingPointService(landingHistoryRepository)

    @Provides
    @Singleton
    fun providePredictionService(@AppScope scope: CoroutineScope): PredictionService =
        PredictionService(scope)

    @Provides
    @Singleton
    fun provideStartupOrchestrator(
        @AppScope scope: CoroutineScope,
        bleService: BleService,
        aprsService: AprsService,
        locationService: LocationService,
        landingHistoryRepository: LandingHistoryRepository
    ): StartupOrchestrator = StartupOrchestrator(
        scope = scope,
        bleService = bleService,
        aprsService = aprsService,
        locationService = locationService,
        landingHistoryRepository = landingHistoryRepository
    )

    @Provides
    @Singleton
    fun provideCoordinator(
        @AppScope scope: CoroutineScope,
        bleService: BleService,
        aprsService: AprsService,
        settingsStore: UserSettingsStore,
        locationService: LocationService,
        routingService: RoutingService,
        notificationHelper: NotificationHelper,
        telemetryLogger: TelemetryLogger,
        positionService: BalloonPositionService,
        trackService: BalloonTrackService,
        landingService: LandingPointService,
        predictionService: PredictionService,
        startupOrchestrator: StartupOrchestrator
    ): BalloonCoordinator {
        return BalloonCoordinator(
            scope = scope,
            bleService = bleService,
            aprsService = aprsService,
            settingsStore = settingsStore,
            locationService = locationService,
            routingService = routingService,
            notificationSink = notificationHelper,
            telemetryLogger = telemetryLogger,
            positionService = positionService,
            trackService = trackService,
            landingService = landingService,
            predictionService = predictionService,
            startupOrchestrator = startupOrchestrator
        )
    }
}