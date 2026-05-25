package ca.roadsense.ns.api

import kotlinx.serialization.KSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonElement
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.util.UUID

/**
 * Wire-format codec that mirrors iOS `JSONEncoder.dateEncodingStrategy = .iso8601`
 * and `JSONEncoder.outputFormatting = .sortedKeys`. Any drift here breaks
 * cross-platform parity with the backend, since the server compares the JSON
 * shape iOS produces.
 */
object UploadCodec {
    val json: Json = Json {
        encodeDefaults = true
        ignoreUnknownKeys = true
        explicitNulls = true
    }

    /**
     * Sort top-level + nested object keys alphabetically. iOS's
     * `JSONEncoder.outputFormatting = .sortedKeys` does this, and we need the
     * same byte order for parity tests.
     */
    fun sortedKeysString(payload: JsonElement): String =
        json.encodeToString(JsonElement.serializer(), payload.sorted())

    private fun JsonElement.sorted(): JsonElement = when (this) {
        is JsonObject -> JsonObject(toSortedMap().mapValues { it.value.sorted() })
        is kotlinx.serialization.json.JsonArray -> kotlinx.serialization.json.JsonArray(map { it.sorted() })
        else -> this
    }
}

/**
 * `Date` ↔ ISO-8601 instant. iOS's `.iso8601` strategy emits seconds-precision
 * `2026-04-10T10:00:00Z`. We match that exactly: drop fractional seconds when
 * the Instant is whole-second; otherwise emit milliseconds (iOS's `.iso8601`
 * only emits whole seconds, but we accept both on read so older clients don't
 * break).
 */
object InstantIso8601Serializer : KSerializer<Instant> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("InstantIso8601", PrimitiveKind.STRING)

    private val whole = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'")

    override fun serialize(encoder: Encoder, value: Instant) {
        val rendered = if (value.nano == 0) {
            whole.withZone(java.time.ZoneOffset.UTC).format(value)
        } else {
            DateTimeFormatter.ISO_INSTANT.format(value)
        }
        encoder.encodeString(rendered)
    }

    override fun deserialize(decoder: Decoder): Instant =
        Instant.parse(decoder.decodeString())
}

/**
 * `UUID` is encoded lowercase to match iOS's lowercased form in URLs and JSON
 * (the iOS test asserts `batch_id` lowercased equals the original UUID string).
 */
object UuidLowercaseSerializer : KSerializer<UUID> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("UuidLowercase", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: UUID) {
        encoder.encodeString(value.toString().lowercase())
    }

    override fun deserialize(decoder: Decoder): UUID = UUID.fromString(decoder.decodeString())
}
