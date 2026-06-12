package ca.roadsense.ns.data

import android.util.Base64
import ca.roadsense.ns.data.room.DeviceTokenDao
import ca.roadsense.ns.data.room.DeviceTokenEntity
import java.security.SecureRandom
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.UUID

class DeviceTokenStore(
    private val dao: DeviceTokenDao,
    private val random: SecureRandom = SecureRandom(),
) {
    suspend fun currentToken(now: Instant = Instant.now()): String {
        val existing = dao.current()
        if (existing != null && existing.expiresAt.isAfter(now)) {
            return existing.token
        }

        val bytes = ByteArray(32)
        random.nextBytes(bytes)
        val token = Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
        dao.upsert(
            DeviceTokenEntity(
                id = UUID.randomUUID(),
                token = token,
                issuedAt = now,
                expiresAt = now.plus(31, ChronoUnit.DAYS),
            ),
        )
        dao.pruneExpiredBefore(now)
        return token
    }
}
