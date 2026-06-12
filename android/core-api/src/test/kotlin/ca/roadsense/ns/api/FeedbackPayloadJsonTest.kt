package ca.roadsense.ns.api

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Wire-format parity with iOS `FeedbackSubmissionPayload`.
 */
class FeedbackPayloadJsonTest {
    private fun encode(payload: FeedbackSubmissionPayload): String {
        val json = UploadCodec.json.encodeToJsonElement(
            FeedbackSubmissionPayload.serializer(),
            payload,
        )
        return UploadCodec.sortedKeysString(json)
    }

    @Test
    fun `payload encodes with sorted keys and explicit nulls`() {
        val payload = FeedbackSubmissionPayload(
            source = "settings",
            category = "bug",
            message = "potholes not appearing on the map",
            replyEmail = null,
            contactConsent = false,
            appVersion = "0.1.0 (1)",
            platform = "Android 14",
            locale = "en-CA",
            route = null,
        )
        val parsed = Json.parseToJsonElement(encode(payload)).jsonObject

        assertEquals(parsed.keys.toList().sorted(), parsed.keys.toList())
        assertEquals("settings", parsed.getValue("source").jsonPrimitive.content)
        assertEquals("bug", parsed.getValue("category").jsonPrimitive.content)
        assertEquals("potholes not appearing on the map", parsed.getValue("message").jsonPrimitive.content)
        assertEquals(false, parsed.getValue("contact_consent").jsonPrimitive.content.toBoolean())
        assertEquals("0.1.0 (1)", parsed.getValue("app_version").jsonPrimitive.content)
        assertEquals("Android 14", parsed.getValue("platform").jsonPrimitive.content)
        assertEquals("en-CA", parsed.getValue("locale").jsonPrimitive.content)
        assertTrue(parsed.containsKey("reply_email"))
        assertTrue(parsed.getValue("reply_email") is JsonNull)
        assertTrue(parsed.containsKey("route"))
        assertTrue(parsed.getValue("route") is JsonNull)
    }

    @Test
    fun `accepted response decodes`() {
        val json = """{"id":"abc","request_id":"req-1"}"""
        val parsed = UploadCodec.json.decodeFromString(
            FeedbackSubmissionAcceptedResponse.serializer(),
            json,
        )
        assertEquals("abc", parsed.id)
        assertEquals("req-1", parsed.requestId)
    }

    @Test
    fun `validation error decodes`() {
        val json = """
            {
              "error": "validation_failed",
              "message": "missing fields",
              "request_id": "req-2",
              "field_errors": {"message": "too_short"}
            }
        """.trimIndent()
        val parsed = UploadCodec.json.decodeFromString(
            FeedbackValidationErrorResponse.serializer(),
            json,
        )
        assertEquals("validation_failed", parsed.error)
        assertEquals("missing fields", parsed.message)
        assertEquals("req-2", parsed.requestId)
        assertEquals("too_short", parsed.fieldErrors.getValue("message"))
    }
}
