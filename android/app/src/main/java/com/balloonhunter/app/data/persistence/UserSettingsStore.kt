package com.balloonhunter.app.data.persistence

import android.content.Context
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.doublePreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.preferencesDataStoreFile
import com.balloonhunter.app.domain.models.TransportationMode
import com.balloonhunter.app.domain.models.UserSettings
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.CoroutineScope

class UserSettingsStore(context: Context, scope: CoroutineScope) {
    private val dataStore = PreferenceDataStoreFactory.create(
        produceFile = { context.preferencesDataStoreFile("user_settings") }
    )

    private object Keys {
        val burstAltitude = doublePreferencesKey("burst_altitude")
        val ascentRate = doublePreferencesKey("ascent_rate")
        val descentRate = doublePreferencesKey("descent_rate")
        val stationId = stringPreferencesKey("station_id")
        val transportMode = intPreferencesKey("transport_mode")
    }

    private val settingsFlow: Flow<UserSettings> = dataStore.data.map { prefs ->
        val mode = when (prefs[Keys.transportMode] ?: 0) {
            1 -> TransportationMode.BIKE
            else -> TransportationMode.CAR
        }
        UserSettings(
            burstAltitude = prefs[Keys.burstAltitude] ?: 30000.0,
            ascentRate = prefs[Keys.ascentRate] ?: 5.0,
            descentRate = prefs[Keys.descentRate] ?: 7.0,
            stationId = prefs[Keys.stationId] ?: "06610",
            transportMode = mode
        )
    }

    val settings: StateFlow<UserSettings> = settingsFlow.stateIn(
        scope,
        SharingStarted.Eagerly,
        UserSettings(
            burstAltitude = 30000.0,
            ascentRate = 5.0,
            descentRate = 7.0,
            stationId = "06610",
            transportMode = TransportationMode.CAR
        )
    )

    suspend fun update(settings: UserSettings) {
        dataStore.edit { prefs ->
            prefs[Keys.burstAltitude] = settings.burstAltitude
            prefs[Keys.ascentRate] = settings.ascentRate
            prefs[Keys.descentRate] = settings.descentRate
            prefs[Keys.stationId] = settings.stationId
            prefs[Keys.transportMode] = if (settings.transportMode == TransportationMode.BIKE) 1 else 0
        }
    }
}
