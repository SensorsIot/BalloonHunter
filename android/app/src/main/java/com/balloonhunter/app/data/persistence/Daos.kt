package com.balloonhunter.app.data.persistence

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

@Dao
interface TrackPointDao {
    @Query("SELECT * FROM track_points ORDER BY epochSeconds ASC")
    suspend fun getAll(): List<TrackPointEntity>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insert(entity: TrackPointEntity)

    @Query("DELETE FROM track_points")
    suspend fun clear()
}

@Dao
interface LandingPointDao {
    @Query("SELECT * FROM landing_points ORDER BY predictedAtEpochSeconds ASC")
    suspend fun getAll(): List<LandingPointEntity>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insert(entity: LandingPointEntity)

    @Query("DELETE FROM landing_points")
    suspend fun clear()
}
