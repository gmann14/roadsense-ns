package ca.roadsense.ns.collection

import ca.roadsense.ns.data.room.DriveSessionDao
import ca.roadsense.ns.data.room.DriveSessionEntity
import ca.roadsense.ns.data.room.ReadingDao
import ca.roadsense.ns.data.room.ReadingEntity
import ca.roadsense.ns.sensor.LocationSample
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.Instant
import java.util.UUID

/**
 * Seam between [CollectionPipeline] and storage for everything tied to a
 * drive session. Keeping it an interface lets pipeline tests run against the
 * real Room implementation or a fake.
 */
interface DriveSessionGateway {
    /** Persists a new open session starting at [start] and returns its id. */
    suspend fun openSession(start: LocationSample): UUID

    /** Persists [reading] if its session is still open and owned by a live
     *  pipeline. Returns false (and writes nothing) otherwise, e.g. after
     *  "Delete local data" wiped the session out from under the pipeline. */
    suspend fun recordReading(reading: ReadingEntity): Boolean

    /** Seals and endpoint-trims [sessionId]. Idempotent. */
    suspend fun sealSession(sessionId: UUID, lastFix: LocationSample?)
}

/**
 * Process-wide owner of drive-session state (held by `RoadSenseContainer`).
 *
 * One [Mutex] serializes session creation, reading writes, sealing, orphan
 * finalization and local-data wipes, and [liveSessions] records which open
 * sessions belong to a running pipeline. That closes the races the
 * 2026-10-18 review found:
 * - two location callbacks can no longer both create a session, and a
 *   reading can no longer be written with `drive_session_id = null`;
 * - the orphan sweep at app/service start cannot seal a session that the
 *   service opened a moment earlier;
 * - a reading cannot land in the database after "Delete local data".
 */
class DriveSessionLifecycle(
    private val driveSessionDao: DriveSessionDao,
    private val readingDao: ReadingDao,
    private val sealer: DriveSessionSealer,
) : DriveSessionGateway {
    private val mutex = Mutex()
    private val liveSessions = mutableSetOf<UUID>()

    override suspend fun openSession(start: LocationSample): UUID = mutex.withLock {
        val id = UUID.randomUUID()
        driveSessionDao.insert(
            DriveSessionEntity(
                id = id,
                startedAt = Instant.ofEpochMilli((start.timestamp * 1000).toLong()),
                startLatitude = start.latitude,
                startLongitude = start.longitude,
            ),
        )
        liveSessions += id
        id
    }

    override suspend fun recordReading(reading: ReadingEntity): Boolean = mutex.withLock {
        val sessionId = reading.driveSessionId ?: return@withLock false
        if (sessionId !in liveSessions) return@withLock false
        readingDao.insert(reading)
        true
    }

    override suspend fun sealSession(sessionId: UUID, lastFix: LocationSample?) {
        mutex.withLock {
            try {
                sealer.sealAndTrim(sessionId, lastFix)
            } finally {
                liveSessions -= sessionId
            }
        }
    }

    /**
     * Seals every unsealed session that no running pipeline owns — the ones a
     * crash, force-stop or OOM kill left open (iOS parity:
     * `finalizeOpenDriveSessions`). Their readings stay invisible to upload
     * until this runs. Returns the sealed sessions.
     */
    suspend fun finalizeOrphans(): List<DriveSessionSealer.Summary> = mutex.withLock {
        driveSessionDao.unsealed()
            .filter { it.id !in liveSessions }
            .mapNotNull { sealer.sealAndTrim(it.id, lastFix = null) }
    }

    /** Runs [wipe] (the "Delete local data" transaction) with every session
     *  write blocked, and forgets live sessions so a pipeline that is still
     *  winding down cannot write into the emptied database. */
    suspend fun <T> wipeLocalData(wipe: suspend () -> T): T = mutex.withLock {
        liveSessions.clear()
        wipe()
    }
}
