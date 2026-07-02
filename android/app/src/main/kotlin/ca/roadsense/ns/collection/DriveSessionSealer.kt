package ca.roadsense.ns.collection

import ca.roadsense.ns.data.room.DriveSessionDao
import ca.roadsense.ns.data.room.ReadingDao
import ca.roadsense.ns.sensor.DriveEndpointTrimmer
import ca.roadsense.ns.sensor.DriveSessionEndpoints
import java.time.Instant
import java.util.UUID

/**
 * Seals a drive session when the drive ends and applies endpoint trimming
 * before any of its readings become upload-eligible.
 *
 * This is the piece that actually enforces the privacy guarantee described by
 * `ReadingEntity.isReadyForUpload`: a drive-attached reading stays invisible
 * to `ReadingDao.pendingForUpload` until `uploadReadyAt` is set here, and
 * readings inside the first/last minute or within 300m of the drive's start
 * or end coordinate are marked `endpointTrimmedAt` and never become eligible
 * at all — mirroring iOS `DriveEndpointTrimmer` + drive-end sealing.
 */
class DriveSessionSealer(
    private val driveSessionDao: DriveSessionDao,
    private val readingDao: ReadingDao,
    private val clock: () -> Instant = Instant::now,
) {
    /**
     * Seals [driveSessionId] and applies endpoint trimming to every reading
     * recorded during the drive. No-op if the session doesn't exist (e.g.
     * collection stopped before any location fix arrived), is already
     * sealed, or has no readings.
     *
     * [endLatitude]/[endLongitude] should be the most recent GPS fix the
     * caller has. When null (no fix arrived after collection last ran — e.g.
     * a crash), falls back to the last recorded reading's coordinate, same
     * as iOS `resolveEndSample`.
     */
    suspend fun sealAndTrim(
        driveSessionId: UUID,
        endLatitude: Double?,
        endLongitude: Double?,
        endedAt: Instant = clock(),
    ) {
        val session = driveSessionDao.findById(driveSessionId) ?: return
        if (session.isSealed) return

        val readings = readingDao.byDriveSession(driveSessionId)

        val resolvedEndLat: Double
        val resolvedEndLng: Double
        if (endLatitude != null && endLongitude != null) {
            resolvedEndLat = endLatitude
            resolvedEndLng = endLongitude
        } else {
            val lastReading = readings.lastOrNull()
            resolvedEndLat = lastReading?.latitude ?: session.startLatitude
            resolvedEndLng = lastReading?.longitude ?: session.startLongitude
        }

        driveSessionDao.seal(driveSessionId, endedAt, resolvedEndLat, resolvedEndLng)

        if (readings.isEmpty()) return

        val endpoints = DriveSessionEndpoints(
            startedAt = session.startedAt,
            endedAt = endedAt,
            startLatitude = session.startLatitude,
            startLongitude = session.startLongitude,
            endLatitude = resolvedEndLat,
            endLongitude = resolvedEndLng,
        )

        val (trimmed, kept) = readings.partition { reading ->
            DriveEndpointTrimmer.shouldTrim(
                readingRecordedAt = reading.recordedAt,
                latitude = reading.latitude,
                longitude = reading.longitude,
                session = endpoints,
            )
        }

        val now = clock()
        if (trimmed.isNotEmpty()) {
            readingDao.markEndpointTrimmed(trimmed.map { it.id }, now)
        }
        if (kept.isNotEmpty()) {
            readingDao.markUploadReady(kept.map { it.id }, now)
        }
    }
}
