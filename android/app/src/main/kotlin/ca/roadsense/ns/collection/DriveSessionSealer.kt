package ca.roadsense.ns.collection

import androidx.room.RoomDatabase
import androidx.room.withTransaction
import ca.roadsense.ns.data.room.DriveSessionDao
import ca.roadsense.ns.data.room.ReadingDao
import ca.roadsense.ns.sensor.DriveEndpointTrimmer
import ca.roadsense.ns.sensor.DriveSessionEndpoints
import ca.roadsense.ns.sensor.LocationSample
import ca.roadsense.ns.sensor.PrivacyZone
import ca.roadsense.ns.sensor.PrivacyZoneFilter
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
 * at all — mirroring iOS `ReadingStore.finalizeDriveSession`.
 *
 * Sealing runs in one Room transaction, so a crash mid-seal leaves the
 * session unsealed (and its readings invisible) rather than half-trimmed; the
 * next orphan sweep finishes the job. A second seal of the same session is a
 * no-op.
 */
class DriveSessionSealer(
    private val database: RoomDatabase,
    private val driveSessionDao: DriveSessionDao,
    private val readingDao: ReadingDao,
    private val privacyZones: suspend () -> List<PrivacyZone> = { emptyList() },
    private val clock: () -> Instant = Instant::now,
) {
    data class Summary(
        val sessionId: UUID,
        val eligibleReadingCount: Int,
        val trimmedReadingCount: Int,
        val privacyDroppedReadingCount: Int,
        val endedAt: Instant,
    )

    /**
     * Seals [driveSessionId] and applies endpoint trimming to every reading
     * recorded during the drive. Returns null (and changes nothing) if the
     * session doesn't exist or is already sealed.
     *
     * End of drive, matching iOS `resolveEndSample`:
     * - end coordinate: whichever is later of [lastFix] (the most recent GPS
     *   fix the pipeline saw) and the last recorded reading; the session start
     *   if neither exists.
     * - `endedAt`: the last reading's `recordedAt`, never the moment Stop was
     *   tapped. A Stop tapped an hour after parking would otherwise push the
     *   time-based end trim an hour past the actual arrival.
     *
     * Privacy zones are re-applied here too, so a zone added mid-drive still
     * drops the readings recorded inside it before they were ever eligible.
     */
    suspend fun sealAndTrim(driveSessionId: UUID, lastFix: LocationSample? = null): Summary? {
        val zones = privacyZones()
        return database.withTransaction {
            sealInTransaction(driveSessionId, lastFix, zones)
        }
    }

    private suspend fun sealInTransaction(
        driveSessionId: UUID,
        lastFix: LocationSample?,
        zones: List<PrivacyZone>,
    ): Summary? {
        val session = driveSessionDao.findById(driveSessionId) ?: return null
        if (session.isSealed) return null

        val readings = readingDao.byDriveSession(driveSessionId)
        val lastReading = readings.lastOrNull()
        val fixAt = lastFix?.let { Instant.ofEpochMilli((it.timestamp * 1000).toLong()) }

        val useFix = lastFix != null && fixAt != null &&
            (lastReading == null || !fixAt.isBefore(lastReading.recordedAt))
        val endLatitude = when {
            useFix -> lastFix!!.latitude
            lastReading != null -> lastReading.latitude
            else -> session.startLatitude
        }
        val endLongitude = when {
            useFix -> lastFix!!.longitude
            lastReading != null -> lastReading.longitude
            else -> session.startLongitude
        }
        val endedAt = (lastReading?.recordedAt ?: fixAt ?: session.startedAt)
            .let { if (it.isBefore(session.startedAt)) session.startedAt else it }

        if (driveSessionDao.seal(driveSessionId, endedAt, endLatitude, endLongitude) == 0) {
            return null
        }

        val now = clock()
        val candidates = readings.filter { !it.droppedByPrivacyZone && it.uploadedAt == null }
        val (inZone, outsideZones) = candidates.partition { reading ->
            PrivacyZoneFilter.isInside(reading.latitude, reading.longitude, zones)
        }
        if (inZone.isNotEmpty()) {
            readingDao.markDroppedByPrivacyZone(inZone.map { it.id })
        }

        val endpoints = DriveSessionEndpoints(
            startedAt = session.startedAt,
            endedAt = endedAt,
            startLatitude = session.startLatitude,
            startLongitude = session.startLongitude,
            endLatitude = endLatitude,
            endLongitude = endLongitude,
        )
        val (trimmed, kept) = outsideZones.partition { reading ->
            DriveEndpointTrimmer.shouldTrim(
                readingRecordedAt = reading.recordedAt,
                latitude = reading.latitude,
                longitude = reading.longitude,
                session = endpoints,
            )
        }
        if (trimmed.isNotEmpty()) {
            readingDao.markEndpointTrimmed(trimmed.map { it.id }, now)
        }
        if (kept.isNotEmpty()) {
            readingDao.markUploadReady(kept.map { it.id }, now)
        }

        return Summary(
            sessionId = driveSessionId,
            eligibleReadingCount = kept.size,
            trimmedReadingCount = trimmed.size,
            privacyDroppedReadingCount = inZone.size,
            endedAt = endedAt,
        )
    }
}
