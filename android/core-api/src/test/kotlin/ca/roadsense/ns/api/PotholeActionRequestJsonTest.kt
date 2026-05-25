package ca.roadsense.ns.api

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.time.Instant
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Wire-format parity for the pothole-actions endpoint. Mirrors
 * `ios/Tests/RoadSenseNSBootstrapTests/UploadRequestFactoryTests.swift`-style
 * assertions for the Swift `PotholeActionUploadRequest` shape so the Edge
 * Function gets the same JSON regardless of client.
 */
class PotholeActionRequestJsonTest {
    private val actionId = UUID.fromString("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
    private val reportId = UUID.fromString("11111111-2222-4333-8444-555555555555")
    private val recordedAt = Instant.ofEpochSecond(1_700_000_000)
    private val clientSentAt = Instant.ofEpochSecond(1_700_000_100)

    private fun encode(request: PotholeActionUploadRequest): String {
        val json = UploadCodec.json.encodeToJsonElement(
            PotholeActionUploadRequest.serializer(),
            request,
        )
        return UploadCodec.sortedKeysString(json)
    }

    @Test
    fun `manual report request matches the iOS contract`() {
        val request = PotholeActionUploadRequest(
            actionId = actionId,
            deviceToken = "device",
            clientSentAt = clientSentAt,
            clientAppVersion = "0.1.0 (1)",
            clientOSVersion = "Android 14",
            actionType = "manual_report",
            potholeReportId = null,
            lat = 44.6488,
            lng = -63.5752,
            accuracyM = 6.4,
            recordedAt = recordedAt,
            sensorBackedMagnitudeG = null,
            sensorBackedAt = null,
        )
        val parsed = Json.parseToJsonElement(encode(request)).jsonObject

        assertEquals(actionId.toString().lowercase(), parsed.getValue("action_id").jsonPrimitive.content)
        assertEquals("manual_report", parsed.getValue("action_type").jsonPrimitive.content)
        assertEquals(44.6488, parsed.getValue("lat").jsonPrimitive.content.toDouble())
        assertEquals(-63.5752, parsed.getValue("lng").jsonPrimitive.content.toDouble())
        assertEquals(6.4, parsed.getValue("accuracy_m").jsonPrimitive.content.toDouble())
        assertEquals("2023-11-14T22:13:20Z", parsed.getValue("recorded_at").jsonPrimitive.content)
        assertEquals("2023-11-14T22:15:00Z", parsed.getValue("client_sent_at").jsonPrimitive.content)
        // Null fields are explicit so backend can distinguish "absent" from "missing key".
        assertTrue(parsed.containsKey("pothole_report_id"))
        assertTrue(parsed.getValue("pothole_report_id") is JsonNull)
    }

    @Test
    fun `confirm-present request carries the original report id`() {
        val request = PotholeActionUploadRequest(
            actionId = actionId,
            deviceToken = "device",
            clientSentAt = clientSentAt,
            clientAppVersion = "0.1.0 (1)",
            clientOSVersion = "Android 14",
            actionType = "confirm_present",
            potholeReportId = reportId,
            lat = 44.65,
            lng = -63.58,
            accuracyM = 7.0,
            recordedAt = recordedAt,
        )
        val parsed = Json.parseToJsonElement(encode(request)).jsonObject
        assertEquals(reportId.toString().lowercase(), parsed.getValue("pothole_report_id").jsonPrimitive.content)
        assertEquals("confirm_present", parsed.getValue("action_type").jsonPrimitive.content)
    }

    @Test
    fun `keys are sorted alphabetically`() {
        val request = PotholeActionUploadRequest(
            actionId = actionId,
            deviceToken = "device",
            clientSentAt = clientSentAt,
            clientAppVersion = "0.1.0 (1)",
            clientOSVersion = "Android 14",
            actionType = "manual_report",
            potholeReportId = null,
            lat = 44.0,
            lng = -63.0,
            accuracyM = 5.0,
            recordedAt = recordedAt,
        )
        val parsed = Json.parseToJsonElement(encode(request)).jsonObject
        val keys = parsed.keys.toList()
        assertEquals(keys.sorted(), keys)
    }

    @Test
    fun `accepted response decodes`() {
        val json = """
            {
              "action_id": "${actionId.toString().lowercase()}",
              "pothole_report_id": "${reportId.toString().lowercase()}",
              "status": "accepted"
            }
        """.trimIndent()
        val parsed = UploadCodec.json.decodeFromString(
            PotholeActionUploadResponse.serializer(),
            json,
        )
        assertEquals(actionId, parsed.actionId)
        assertEquals(reportId, parsed.potholeReportId)
        assertEquals("accepted", parsed.status)
    }
}
