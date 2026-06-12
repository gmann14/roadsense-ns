package ca.roadsense.ns.api

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant
import java.util.UUID

/**
 * Wire-format mirror of iOS `PotholeActionUploadRequest`. Field names + JSON
 * keys match exactly so the same `pothole-actions` Edge Function handles both
 * platforms without server changes (per docs/implementation/12-android-implementation.md).
 */
@Serializable
data class PotholeActionUploadRequest(
    @SerialName("action_id") @Serializable(with = UuidLowercaseSerializer::class) val actionId: UUID,
    @SerialName("device_token") val deviceToken: String,
    @SerialName("client_sent_at") @Serializable(with = InstantIso8601Serializer::class) val clientSentAt: Instant,
    @SerialName("client_app_version") val clientAppVersion: String,
    @SerialName("client_os_version") val clientOSVersion: String,
    @SerialName("action_type") val actionType: String,
    @SerialName("pothole_report_id") @Serializable(with = UuidLowercaseSerializer::class) val potholeReportId: UUID? = null,
    @SerialName("lat") val lat: Double,
    @SerialName("lng") val lng: Double,
    @SerialName("accuracy_m") val accuracyM: Double,
    @SerialName("recorded_at") @Serializable(with = InstantIso8601Serializer::class) val recordedAt: Instant,
    @SerialName("sensor_backed_magnitude_g") val sensorBackedMagnitudeG: Double? = null,
    @SerialName("sensor_backed_at") @Serializable(with = InstantIso8601Serializer::class) val sensorBackedAt: Instant? = null,
)

@Serializable
data class PotholeActionUploadResponse(
    @SerialName("action_id") @Serializable(with = UuidLowercaseSerializer::class) val actionId: UUID,
    @SerialName("pothole_report_id") @Serializable(with = UuidLowercaseSerializer::class) val potholeReportId: UUID,
    @SerialName("status") val status: String,
)
