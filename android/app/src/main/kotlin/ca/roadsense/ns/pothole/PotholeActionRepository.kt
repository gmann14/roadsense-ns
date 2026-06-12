package ca.roadsense.ns.pothole

import ca.roadsense.ns.data.room.PotholeActionDao
import ca.roadsense.ns.data.room.PotholeActionEntity
import ca.roadsense.ns.data.room.PotholeActionUploadState
import java.time.Instant
import java.util.UUID

/**
 * UI-facing repository for the manual pothole flow. Mirrors iOS
 * `PotholeActionStore`. Persists rows in PENDING_UNDO when the user reports a
 * pothole, supports the undo gesture during the 8-second window, and flips
 * the row to PENDING_UPLOAD when the window expires.
 */
class PotholeActionRepository(
    private val dao: PotholeActionDao,
    private val clock: () -> Instant = { Instant.now() },
) {
    /** Persist a new manual_report in PENDING_UNDO state. Returns the row id. */
    suspend fun reportPothole(location: PotholeLocation): UUID {
        val now = clock()
        val entity = PotholeActionCoordinator.manualReport(location, now)
        dao.insert(entity)
        return entity.id
    }

    /** Cancel a row that's still inside the undo window. Returns true if
     *  the row existed and was deletable (i.e. still in PENDING_UNDO and
     *  before its expiry). */
    suspend fun undo(actionId: UUID): Boolean {
        val existing = dao.findById(actionId) ?: return false
        if (existing.uploadState != PotholeActionUploadState.PENDING_UNDO.wireValue) return false
        val expires = existing.undoExpiresAt ?: return false
        if (clock().isAfter(expires)) return false
        return dao.delete(actionId) > 0
    }

    /** Promote a single row from PENDING_UNDO → PENDING_UPLOAD. Idempotent.
     *  Clears `undoExpiresAt` so the upload-drain query (which requires
     *  `undo_expires_at IS NULL OR undo_expires_at <= now`) sees the row
     *  regardless of how the upload-drain caller's clock compares to the
     *  row's original expiry. */
    suspend fun promoteIfReady(actionId: UUID): Boolean {
        val row = dao.findById(actionId) ?: return false
        if (row.uploadState != PotholeActionUploadState.PENDING_UNDO.wireValue) return false
        val expires = row.undoExpiresAt ?: return false
        if (clock().isBefore(expires)) return false
        dao.update(
            row.copy(
                uploadState = PotholeActionUploadState.PENDING_UPLOAD.wireValue,
                undoExpiresAt = null,
            )
        )
        return true
    }

    /** Sweep all rows whose undo window has elapsed and promote them to
     *  PENDING_UPLOAD so the next upload-drain pass picks them up. Returns the
     *  number promoted. */
    suspend fun promoteExpiredUndos(): Int {
        val now = clock()
        val rows = dao.expiredUndos(
            pendingUndo = PotholeActionUploadState.PENDING_UNDO.wireValue,
            now = now,
        )
        rows.forEach {
            dao.update(
                it.copy(
                    uploadState = PotholeActionUploadState.PENDING_UPLOAD.wireValue,
                    undoExpiresAt = null,
                )
            )
        }
        return rows.size
    }

    suspend fun pendingUploadCount(): Int = dao.pendingUploadCount(
        pendingUpload = PotholeActionUploadState.PENDING_UPLOAD.wireValue,
    )

    suspend fun get(actionId: UUID): PotholeActionEntity? = dao.findById(actionId)
}
