package com.balloonhunter.app.data.persistence

import androidx.room.Database
import androidx.room.RoomDatabase

@Database(
    entities = [TrackPointEntity::class, LandingPointEntity::class],
    version = 1,
    exportSchema = false
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun trackPointDao(): TrackPointDao
    abstract fun landingPointDao(): LandingPointDao
}
