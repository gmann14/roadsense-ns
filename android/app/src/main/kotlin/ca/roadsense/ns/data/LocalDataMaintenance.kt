package ca.roadsense.ns.data

import androidx.room.withTransaction
import ca.roadsense.ns.AppLog
import ca.roadsense.ns.api.RetentionPolicy
import ca.roadsense.ns.collection.DriveSessionLifecycle
import ca.roadsense.ns.data.room.FeedbackUploadState
import ca.roadsense.ns.data.room.PotholeActionUploadState
import ca.roadsense.ns.data.room.RoadSenseDatabase
import ca.roadsense.ns.data.room.UploadBatchState
import java.io.File
import java.time.Instant

/**
 * Settings → "Delete local data". One Room transaction clears every table
 * (so a crash can't leave half the data behind), session writes are blocked
 * while it runs, and photo files are removed from disk as well as their rows.
 * Mirrors iOS Settings → "Erase locally stored RoadSense data".
 */
class LocalDataWiper(
    private val database: RoadSenseDatabase,
    private val driveSessions: DriveSessionLifecycle,
    private val photoDirectory: File?,
) {
    suspend fun wipe() {
        val photoPaths = driveSessions.wipeLocalData {
            database.withTransaction {
                val paths = database.potholePhotoDao().allFilePaths()
                database.readingDao().deleteAll()
                database.uploadBatchDao().deleteAll()
                database.potholeActionDao().deleteAll()
                database.potholePhotoDao().deleteAll()
                database.privacyZoneDao().deleteAll()
                database.driveSessionDao().deleteAll()
                database.feedbackDao().deleteAll()
                database.userStatsDao().deleteAll()
                // Clearing forces a fresh token so the wipe doesn't keep
                // linking new uploads to the prior token's server-side hash.
                database.deviceTokenDao().deleteAll()
                paths
            }
        }
        photoPaths.forEach { deleteQuietly(File(it)) }
        photoDirectory?.let { dir -> if (dir.exists()) dir.deleteRecursively() }
    }

    private fun deleteQuietly(file: File) {
        try {
            if (file.exists() && !file.delete()) AppLog.warn("could not delete a local photo file")
        } catch (e: SecurityException) {
            AppLog.warn("could not delete a local photo file", e)
        }
    }
}

/**
 * Applies [RetentionPolicy] to everything finished on the device. Runs on the
 * periodic upload heartbeat. Pending, not-yet-uploaded data is never pruned.
 */
class LocalRetentionPruner(private val database: RoadSenseDatabase) {
    data class Result(
        val readings: Int,
        val batches: Int,
        val driveSessions: Int,
        val potholeActions: Int,
        val feedback: Int,
        val deviceTokens: Int,
    ) {
        val total: Int
            get() = readings + batches + driveSessions + potholeActions + feedback + deviceTokens
    }

    suspend fun prune(now: Instant = Instant.now()): Result {
        val cutoff = RetentionPolicy.cutoff(now)
        return database.withTransaction {
            // Readings first: the never-uploadable query looks up failed
            // batches, which are deleted right after.
            val readings = database.readingDao().pruneUploadedBefore(cutoff) +
                database.readingDao().pruneNeverUploadableBefore(cutoff)
            val batches = database.uploadBatchDao().pruneTerminalBefore(UploadBatchState.SUCCEEDED, cutoff) +
                database.uploadBatchDao().pruneTerminalBefore(UploadBatchState.FAILED_PERMANENT, cutoff)
            val sessions = database.driveSessionDao().pruneSealedBefore(cutoff)
            val actions = database.potholeActionDao().pruneFinishedBefore(
                terminalStates = listOf(
                    PotholeActionUploadState.SUBMITTED.wireValue,
                    PotholeActionUploadState.FAILED_PERMANENT.wireValue,
                ),
                cutoff = cutoff,
            )
            val feedback = database.feedbackDao().pruneFinishedBefore(
                pending = FeedbackUploadState.PENDING.wireValue,
                cutoff = cutoff,
            )
            val tokens = database.deviceTokenDao().pruneExpiredBefore(now)
            Result(readings, batches, sessions, actions, feedback, tokens)
        }
    }
}
