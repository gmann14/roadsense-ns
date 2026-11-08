package ca.roadsense.ns.data

import ca.roadsense.ns.data.room.DeviceTokenDao
import ca.roadsense.ns.data.room.DeviceTokenEntity
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.UUID

/**
 * Anonymous, rotating device token sent with every write request.
 *
 * The token MUST be a lowercase UUIDv4 string: `upload-readings`,
 * `pothole-actions` and `pothole-photos` all validate `device_token` against
 * `UUID_V4_REGEX` (see `supabase/functions/upload-readings/handler.ts`) and
 * answer anything else with a permanent 400. Mirrors iOS
 * `DeviceTokenManager`, which mints `UUID().uuidString`.
 *
 * Builds before this fix stored a 43-character base64url token. Any stored
 * token that is not a UUIDv4 is treated as invalid and replaced, so upgraded
 * installs start uploading again without a data wipe.
 */
class DeviceTokenStore(
    private val dao: DeviceTokenDao,
    private val makeToken: () -> String = { UUID.randomUUID().toString() },
) {
    suspend fun currentToken(now: Instant = Instant.now()): String {
        val existing = dao.current()
        if (existing != null && existing.expiresAt.isAfter(now) && isValidToken(existing.token)) {
            return existing.token
        }

        val token = makeToken().lowercase()
        check(isValidToken(token)) { "device token generator must produce a UUIDv4" }
        if (existing != null) {
            // Drop the expired or legacy-format row so `current()` can never
            // hand the old value back.
            dao.deleteAll()
        }
        dao.upsert(
            DeviceTokenEntity(
                id = UUID.randomUUID(),
                token = token,
                issuedAt = now,
                expiresAt = now.plus(TOKEN_LIFETIME_DAYS, ChronoUnit.DAYS),
            ),
        )
        dao.pruneExpiredBefore(now)
        return token
    }

    companion object {
        /** Rotation period; matches iOS `DeviceTokenManager`. */
        const val TOKEN_LIFETIME_DAYS: Long = 30

        /** Same shape the server enforces (`UUID_V4_REGEX` in the edge handlers). */
        private val UUID_V4 =
            Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", RegexOption.IGNORE_CASE)

        fun isValidToken(token: String): Boolean = UUID_V4.matches(token)
    }
}
