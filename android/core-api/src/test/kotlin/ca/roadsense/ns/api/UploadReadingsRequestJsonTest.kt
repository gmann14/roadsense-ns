package ca.roadsense.ns.api

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.time.Instant
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Wire-format parity with iOS. The expectations below mirror
 * `ios/Tests/RoadSenseNSBootstrapTests/UploadRequestFactoryTests.swift` so an
 * Android client and an iOS client produce the same JSON byte-for-byte for
 * the same logical request.
 *
 * If this test fails, the backend will reject Android uploads in shapes iOS
 * would not. Do not "fix" by editing the expected JSON — fix by bringing the
 * Kotlin DTOs / codec back in line with iOS.
 */
class UploadReadingsRequestJsonTest {
    private val batchId = UUID.fromString("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
    private val recordedAt = Instant.ofEpochSecond(1_700_000_000)
    private val clientSentAt = Instant.ofEpochSecond(1_700_000_100)

    private val request = UploadReadingsRequest(
        batchId = batchId,
        deviceToken = "11111111-2222-4333-8444-555555555555",
        clientSentAt = clientSentAt,
        clientAppVersion = "0.1.0 (1)",
        clientOSVersion = "Android 14",
        readings = listOf(
            UploadReadingPayload(
                lat = 44.6488,
                lng = -63.5752,
                roughnessRms = 0.72,
                speedKmh = 57.2,
                heading = 92.0,
                gpsAccuracyM = 6.4,
                isPothole = true,
                potholeMagnitude = 1.9,
                recordedAt = recordedAt,
            )
        ),
    )

    @Test
    fun `top-level shape matches iOS contract`() {
        val parsed = Json.parseToJsonElement(UploadRequestFactory.encode(request)).jsonObject

        assertEquals(
            batchId.toString().lowercase(),
            parsed.getValue("batch_id").jsonPrimitive.content,
        )
        assertEquals("11111111-2222-4333-8444-555555555555", parsed.getValue("device_token").jsonPrimitive.content)
        assertEquals("2023-11-14T22:15:00Z", parsed.getValue("client_sent_at").jsonPrimitive.content)
        assertEquals("0.1.0 (1)", parsed.getValue("client_app_version").jsonPrimitive.content)
        assertEquals("Android 14", parsed.getValue("client_os_version").jsonPrimitive.content)
    }

    @Test
    fun `reading payload shape matches iOS contract`() {
        val parsed = Json.parseToJsonElement(UploadRequestFactory.encode(request)).jsonObject
        val reading = parsed.getValue("readings").jsonArray[0].jsonObject

        assertEquals(44.6488, reading.getValue("lat").jsonPrimitive.double)
        assertEquals(-63.5752, reading.getValue("lng").jsonPrimitive.double)
        assertEquals(0.72, reading.getValue("roughness_rms").jsonPrimitive.double)
        assertEquals(57.2, reading.getValue("speed_kmh").jsonPrimitive.double)
        assertEquals(92.0, reading.getValue("heading").jsonPrimitive.double)
        assertEquals(6.4, reading.getValue("gps_accuracy_m").jsonPrimitive.double)
        assertEquals(true, reading.getValue("is_pothole").jsonPrimitive.boolean)
        assertEquals(1.9, reading.getValue("pothole_magnitude").jsonPrimitive.double)
        assertEquals("2023-11-14T22:13:20Z", reading.getValue("recorded_at").jsonPrimitive.content)
    }

    @Test
    fun `keys are sorted alphabetically at every object level`() {
        val parsed = Json.parseToJsonElement(UploadRequestFactory.encode(request)).jsonObject
        val topKeys = parsed.keys.toList()
        assertEquals(topKeys.sorted(), topKeys, "top-level keys should be sorted, got $topKeys")

        val readingKeys = parsed.getValue("readings").jsonArray[0].jsonObject.keys.toList()
        assertEquals(readingKeys.sorted(), readingKeys, "reading keys should be sorted, got $readingKeys")
    }

    @Test
    fun `top-level encoded byte form matches exact iOS shape`() {
        // Exact wire form an iOS client produces for the same logical request
        // (`.iso8601` dates, sorted keys, lowercase UUID). The backend compares
        // these JSON shapes — drift here breaks parity.
        val expected = buildString {
            append('{')
            append(""""batch_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",""")
            append(""""client_app_version":"0.1.0 (1)",""")
            append(""""client_os_version":"Android 14",""")
            append(""""client_sent_at":"2023-11-14T22:15:00Z",""")
            append(""""device_token":"11111111-2222-4333-8444-555555555555",""")
            append(""""readings":[""")
            append('{')
            append(""""gps_accuracy_m":6.4,""")
            append(""""heading":92.0,""")
            append(""""is_pothole":true,""")
            append(""""lat":44.6488,""")
            append(""""lng":-63.5752,""")
            append(""""pothole_magnitude":1.9,""")
            append(""""recorded_at":"2023-11-14T22:13:20Z",""")
            append(""""roughness_rms":0.72,""")
            append(""""speed_kmh":57.2""")
            append("}]")
            append('}')
        }
        assertEquals(expected, UploadRequestFactory.encode(request))
    }

    @Test
    fun `pothole_magnitude null is encoded explicitly`() {
        val nullMagnitude = request.copy(
            readings = listOf(request.readings.first().copy(isPothole = false, potholeMagnitude = null))
        )
        val parsed = Json.parseToJsonElement(UploadRequestFactory.encode(nullMagnitude)).jsonObject
        val reading = parsed.getValue("readings").jsonArray[0].jsonObject
        assertEquals(true, reading.containsKey("pothole_magnitude"))
        assertEquals(true, reading.getValue("pothole_magnitude") is kotlinx.serialization.json.JsonNull)
    }

    @Test
    fun `accepted response decodes`() {
        val responseJson = """
            {
              "batch_id": "${batchId.toString().lowercase()}",
              "accepted": 7,
              "rejected": 1,
              "duplicate": false,
              "rejected_reasons": {"low_quality": 1}
            }
        """.trimIndent()

        val response = UploadCodec.json.decodeFromString(UploadReadingsResponse.serializer(), responseJson)
        assertEquals(batchId, response.batchId)
        assertEquals(7, response.accepted)
        assertEquals(1, response.rejected)
        assertEquals(false, response.duplicate)
        assertEquals(1, response.rejectedReasons.getValue("low_quality"))
    }

    @Test
    fun `error envelope decodes`() {
        val errorJson = """{"error":"bad_request","details":{"reason":"missing_field"}}"""
        val envelope = UploadCodec.json.decodeFromString(UploadErrorEnvelope.serializer(), errorJson)
        assertEquals("bad_request", envelope.error)
        assertEquals("missing_field", envelope.details?.getValue("reason"))
    }
}
