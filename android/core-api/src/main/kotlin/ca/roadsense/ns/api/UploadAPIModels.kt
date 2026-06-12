package ca.roadsense.ns.api

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant
import java.util.UUID

@Serializable
data class UploadReadingPayload(
    @SerialName("lat") val lat: Double,
    @SerialName("lng") val lng: Double,
    @SerialName("roughness_rms") val roughnessRms: Double,
    @SerialName("speed_kmh") val speedKmh: Double,
    @SerialName("heading") val heading: Double,
    @SerialName("gps_accuracy_m") val gpsAccuracyM: Double,
    @SerialName("is_pothole") val isPothole: Boolean,
    @SerialName("pothole_magnitude") val potholeMagnitude: Double?,
    @SerialName("recorded_at") @Serializable(with = InstantIso8601Serializer::class) val recordedAt: Instant,
)

@Serializable
data class UploadReadingsRequest(
    @SerialName("batch_id") @Serializable(with = UuidLowercaseSerializer::class) val batchId: UUID,
    @SerialName("device_token") val deviceToken: String,
    @SerialName("client_sent_at") @Serializable(with = InstantIso8601Serializer::class) val clientSentAt: Instant,
    @SerialName("client_app_version") val clientAppVersion: String,
    @SerialName("client_os_version") val clientOSVersion: String,
    @SerialName("readings") val readings: List<UploadReadingPayload>,
)

@Serializable
data class UploadReadingsResponse(
    @SerialName("batch_id") @Serializable(with = UuidLowercaseSerializer::class) val batchId: UUID,
    @SerialName("accepted") val accepted: Int,
    @SerialName("rejected") val rejected: Int,
    @SerialName("duplicate") val duplicate: Boolean,
    @SerialName("rejected_reasons") val rejectedReasons: Map<String, Int> = emptyMap(),
)

@Serializable
data class UploadErrorEnvelope(
    @SerialName("error") val error: String,
    @SerialName("details") val details: Map<String, String>? = null,
)

object UploadRequestFactory {
    fun encode(request: UploadReadingsRequest): String {
        // Use sortedKeysString to guarantee the same byte order iOS produces
        // via JSONEncoder.outputFormatting = .sortedKeys.
        val element = UploadCodec.json.encodeToJsonElement(UploadReadingsRequest.serializer(), request)
        return UploadCodec.sortedKeysString(element)
    }
}
