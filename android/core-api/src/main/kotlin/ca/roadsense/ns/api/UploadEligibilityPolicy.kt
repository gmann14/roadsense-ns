package ca.roadsense.ns.api

import java.time.Instant

enum class NetworkPathStatus { SATISFIED, UNSATISFIED }

data class NetworkPathSnapshot(
    val status: NetworkPathStatus,
    val isExpensive: Boolean,
)

object UploadEligibilityPolicy {
    fun shouldUpload(
        pendingCount: Int,
        network: NetworkPathSnapshot,
        nextAttemptAt: Instant? = null,
        now: Instant = Instant.now(),
    ): Boolean {
        if (network.status != NetworkPathStatus.SATISFIED) return false
        if (pendingCount <= 0) return false
        if (nextAttemptAt != null && nextAttemptAt > now) return false
        return true
    }
}
