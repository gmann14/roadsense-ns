package ca.roadsense.ns.api

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.jupiter.api.Test
import java.time.Instant
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Wire-format parity with iOS `PotholePhotoUploadRequest`
 * (`ios/Sources/RoadSenseNSBootstrap/Network/UploadAPIModels.swift`).
 * The `POST /pothole-photos` Edge Function compares the JSON shape iOS
 * produces; drift would silently break photo metadata submission.
 *
 * Backend contract: `docs/implementation/03-api-contracts.md` →
 * `POST /pothole-photos`.
 */
class PotholePhotoRequestJsonTest {

    private fun encode(payload: PotholePhotoUploadRequest): String {
        val element = UploadCodec.json.encodeToJsonElement(
            PotholePhotoUploadRequest.serializer(),
            payload,
        )
        return UploadCodec.sortedKeysString(element)
    }

    @Test
    fun `request encodes with sorted keys and explicit nulls`() {
        val payload = PotholePhotoUploadRequest(
            reportId = UUID.fromString("c2f1a4b3-1234-4c5d-8e9f-112233445566"),
            segmentId = null,
            deviceToken = UUID.fromString("a78f9e2b-4c6d-11ec-81d3-0242ac130003"),
            clientSentAt = Instant.parse("2026-04-21T18:22:05Z"),
            clientAppVersion = "0.2.0 (78)",
            clientOSVersion = "Android 14",
            lat = 44.6488,
            lng = -63.5752,
            accuracyM = 6.8,
            capturedAt = Instant.parse("2026-04-21T18:22:00Z"),
            contentType = "image/jpeg",
            byteSize = 312_840,
            sha256 = "9b74c9897bac770ffc029102a200c5de",
        )
        val parsed = Json.parseToJsonElement(encode(payload)).jsonObject

        // Keys must be in sorted order to match iOS `.sortedKeys` output.
        assertEquals(parsed.keys.toList().sorted(), parsed.keys.toList())

        assertEquals("c2f1a4b3-1234-4c5d-8e9f-112233445566", parsed.getValue("report_id").jsonPrimitive.content)
        assertTrue(parsed.containsKey("segment_id"))
        assertTrue(parsed.getValue("segment_id") is JsonNull)
        assertEquals("a78f9e2b-4c6d-11ec-81d3-0242ac130003", parsed.getValue("device_token").jsonPrimitive.content)
        assertEquals("2026-04-21T18:22:05Z", parsed.getValue("client_sent_at").jsonPrimitive.content)
        assertEquals("0.2.0 (78)", parsed.getValue("client_app_version").jsonPrimitive.content)
        assertEquals("Android 14", parsed.getValue("client_os_version").jsonPrimitive.content)
        assertEquals(44.6488, parsed.getValue("lat").jsonPrimitive.content.toDouble())
        assertEquals(-63.5752, parsed.getValue("lng").jsonPrimitive.content.toDouble())
        assertEquals(6.8, parsed.getValue("accuracy_m").jsonPrimitive.content.toDouble())
        assertEquals("2026-04-21T18:22:00Z", parsed.getValue("captured_at").jsonPrimitive.content)
        assertEquals("image/jpeg", parsed.getValue("content_type").jsonPrimitive.content)
        assertEquals(312_840L, parsed.getValue("byte_size").jsonPrimitive.content.toLong())
        assertEquals("9b74c9897bac770ffc029102a200c5de", parsed.getValue("sha256").jsonPrimitive.content)
    }

    @Test
    fun `segment id encodes lowercase when present`() {
        val payload = PotholePhotoUploadRequest(
            reportId = UUID.fromString("c2f1a4b3-1234-4c5d-8e9f-112233445566"),
            segmentId = UUID.fromString("92ABED15-D273-4BD3-92EC-D4F0C8B82F99"),
            deviceToken = UUID.fromString("a78f9e2b-4c6d-11ec-81d3-0242ac130003"),
            clientSentAt = Instant.parse("2026-04-21T18:22:05Z"),
            clientAppVersion = "0.2.0 (78)",
            clientOSVersion = "Android 14",
            lat = 44.6488,
            lng = -63.5752,
            accuracyM = 6.8,
            capturedAt = Instant.parse("2026-04-21T18:22:00Z"),
            contentType = "image/jpeg",
            byteSize = 312_840,
            sha256 = "9b74c9897bac770ffc029102a200c5de",
        )
        val parsed = Json.parseToJsonElement(encode(payload)).jsonObject
        // iOS encodes UUIDs lowercased; we match.
        assertEquals(
            "92abed15-d273-4bd3-92ec-d4f0c8b82f99",
            parsed.getValue("segment_id").jsonPrimitive.content,
        )
    }

    @Test
    fun `success response decodes`() {
        val json = """
            {
              "report_id": "c2f1a4b3-1234-4c5d-8e9f-112233445566",
              "upload_url": "https://example.supabase.co/storage/v1/object/sign/pothole-photos/pending/c2f1a4b3.jpg?token=abc",
              "upload_expires_at": "2026-04-21T20:22:05Z",
              "expected_object_path": "pending/c2f1a4b3.jpg"
            }
        """.trimIndent()
        val parsed = UploadCodec.json.decodeFromString(
            PotholePhotoUploadResponse.serializer(),
            json,
        )
        assertEquals(UUID.fromString("c2f1a4b3-1234-4c5d-8e9f-112233445566"), parsed.reportId)
        assertTrue(parsed.uploadURL.startsWith("https://example.supabase.co/"))
        assertEquals(Instant.parse("2026-04-21T20:22:05Z"), parsed.uploadExpiresAt)
        assertEquals("pending/c2f1a4b3.jpg", parsed.expectedObjectPath)
    }

    @Test
    fun `already-uploaded response decodes`() {
        val json = """
            {
              "error": "already_uploaded",
              "message": "This report_id has already been submitted.",
              "request_id": "01H9Z..."
            }
        """.trimIndent()
        val parsed = UploadCodec.json.decodeFromString(
            PotholePhotoAlreadyUploadedResponse.serializer(),
            json,
        )
        assertEquals("already_uploaded", parsed.error)
        assertEquals("01H9Z...", parsed.requestId)
    }
}
