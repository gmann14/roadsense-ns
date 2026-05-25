package ca.roadsense.ns.data.network

import ca.roadsense.ns.api.AppConfig
import ca.roadsense.ns.api.Endpoints
import ca.roadsense.ns.api.FeedbackSubmissionAcceptedResponse
import ca.roadsense.ns.api.FeedbackSubmissionPayload
import ca.roadsense.ns.api.FeedbackSubmissionResult
import ca.roadsense.ns.api.FeedbackValidationErrorResponse
import ca.roadsense.ns.api.PotholeActionUploadRequest
import ca.roadsense.ns.api.PotholeActionUploadResponse
import ca.roadsense.ns.api.UploadCodec
import ca.roadsense.ns.api.UploadReadingsRequest
import ca.roadsense.ns.api.UploadReadingsResponse
import com.jakewharton.retrofit2.converter.kotlinx.serialization.asConverterFactory
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Response
import okhttp3.logging.HttpLoggingInterceptor
import retrofit2.Retrofit
import retrofit2.http.Body
import retrofit2.http.POST
import retrofit2.http.Url
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Retrofit interface mirroring iOS `APIClient`. Each method returns a
 * Retrofit `Response` so the caller can read HTTP status + headers (needed
 * for `Retry-After` parsing in `UploadPolicy`).
 *
 * Endpoints are passed as `@Url` so we don't bake a baseUrl into the
 * Retrofit instance — `AppConfig.functionsBaseURL` is environment-dependent
 * (local / staging / production) and we already have an Endpoints helper.
 */
interface BackendApi {
    @POST
    suspend fun uploadReadings(
        @Url url: String,
        @Body request: UploadReadingsRequest,
    ): retrofit2.Response<UploadReadingsResponse>

    @POST
    suspend fun submitPotholeAction(
        @Url url: String,
        @Body request: PotholeActionUploadRequest,
    ): retrofit2.Response<PotholeActionUploadResponse>

    @POST
    suspend fun submitFeedback(
        @Url url: String,
        @Body request: FeedbackSubmissionPayload,
    ): retrofit2.Response<okhttp3.ResponseBody>
}

class AuthHeaderInterceptor(private val supabaseAnonKey: String) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request().newBuilder()
            .addHeader("Content-Type", "application/json")
            .addHeader("Accept", "application/json")
            .addHeader("apikey", supabaseAnonKey)
            .addHeader("Authorization", "Bearer $supabaseAnonKey")
            .build()
        return chain.proceed(request)
    }
}

object HttpClientFactory {
    fun build(config: AppConfig, debug: Boolean): OkHttpClient {
        val builder = OkHttpClient.Builder()
            .addInterceptor(AuthHeaderInterceptor(config.supabaseAnonKey))
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)

        if (debug) {
            // Body-level logging only in debug. Production is HEADERS at most
            // because reading payloads contain coarse coordinates we don't
            // want sitting in adb logcat unredacted.
            builder.addInterceptor(HttpLoggingInterceptor().apply {
                level = HttpLoggingInterceptor.Level.BODY
            })
        }
        return builder.build()
    }
}

class BackendClient(
    val config: AppConfig,
    private val httpClient: OkHttpClient = HttpClientFactory.build(config, debug = false),
) {
    val endpoints: Endpoints = Endpoints(config)

    @OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
    private val retrofit: Retrofit = Retrofit.Builder()
        // We pass full URLs via @Url so this is a placeholder; Retrofit
        // requires *some* baseUrl, but it's never actually applied.
        .baseUrl(config.functionsBaseURL.trimEnd('/') + "/")
        .client(httpClient)
        .addConverterFactory(
            UploadCodec.json.asConverterFactory("application/json".toMediaType()),
        )
        .build()

    private val api: BackendApi = retrofit.create(BackendApi::class.java)

    suspend fun uploadReadings(request: UploadReadingsRequest): retrofit2.Response<UploadReadingsResponse> =
        api.uploadReadings(endpoints.uploadReadingsURL, request)

    suspend fun submitPotholeAction(
        request: PotholeActionUploadRequest,
    ): retrofit2.Response<PotholeActionUploadResponse> =
        api.submitPotholeAction(endpoints.potholeActionsURL, request)

    /**
     * Mirrors iOS `submitFeedback`: maps HTTP status codes onto a typed
     * `FeedbackSubmissionResult` instead of bubbling raw response objects to
     * the queue drainer. Network failures become `NetworkError` so the
     * queue retries instead of permanent-failing.
     */
    suspend fun submitFeedback(payload: FeedbackSubmissionPayload): FeedbackSubmissionResult {
        val response = try {
            api.submitFeedback(endpoints.feedbackURL, payload)
        } catch (e: IOException) {
            return FeedbackSubmissionResult.NetworkError(e)
        }

        val requestId = response.headers()["x-request-id"]
        val retryAfter = response.headers()["Retry-After"]?.toDoubleOrNull()
        val rawBody = response.errorBody()?.string() ?: response.body()?.string()

        return when (response.code()) {
            201 -> {
                val body = rawBody?.let {
                    runCatching {
                        UploadCodec.json.decodeFromString(
                            FeedbackSubmissionAcceptedResponse.serializer(),
                            it,
                        )
                    }.getOrNull()
                }
                FeedbackSubmissionResult.Accepted(
                    id = body?.id ?: "",
                    requestId = body?.requestId ?: requestId,
                )
            }
            400 -> {
                val envelope = rawBody?.let {
                    runCatching {
                        UploadCodec.json.decodeFromString(
                            FeedbackValidationErrorResponse.serializer(),
                            it,
                        )
                    }.getOrNull()
                }
                FeedbackSubmissionResult.ValidationFailed(
                    fieldErrors = envelope?.fieldErrors ?: emptyMap(),
                    requestId = envelope?.requestId ?: requestId,
                )
            }
            429 -> FeedbackSubmissionResult.RateLimited(
                retryAfterSeconds = retryAfter,
                requestId = requestId,
            )
            else -> FeedbackSubmissionResult.ServerError(
                statusCode = response.code(),
                requestId = requestId,
            )
        }
    }
}
