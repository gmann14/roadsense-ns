package ca.roadsense.ns.api

import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.util.UUID

class Endpoints(val config: AppConfig) {
    val uploadReadingsURL: String get() = "${config.functionsBaseURL}/upload-readings"
    val potholeActionsURL: String get() = "${config.functionsBaseURL}/pothole-actions"
    val potholePhotosURL: String get() = "${config.functionsBaseURL}/pothole-photos"
    val feedbackURL: String get() = "${config.functionsBaseURL}/feedback"

    fun segmentDetailURL(id: UUID): String =
        "${config.functionsBaseURL}/segments/${id.toString().lowercase()}"

    val tileTemplateURLString: String
        get() {
            val encodedAnonKey = URLEncoder.encode(config.supabaseAnonKey, StandardCharsets.UTF_8)
            val base = config.functionsBaseURL.trimEnd('/')
            return "$base/tiles/{z}/{x}/{y}.mvt?apikey=$encodedAnonKey"
        }

    fun tileURL(z: Int, x: Int, y: Int, version: Int? = null): String {
        val base = "${config.functionsBaseURL}/tiles/$z/$x/$y.mvt"
        return if (version == null) base else "$base?v=$version"
    }
}
