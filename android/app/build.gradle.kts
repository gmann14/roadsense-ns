import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
    id("com.google.devtools.ksp")
}

/** Mirrors the iOS xcconfig pattern: per-environment defaults committed with
 *  placeholder Mapbox/Sentry secrets, and an optional sibling
 *  `<env>.secrets.properties` (gitignored) that overrides anything. */
fun loadEnvProperties(envName: String): Properties {
    val props = Properties()
    val configDir = file("$rootDir/config")
    val defaults = configDir.resolve("$envName.env.properties")
    val secrets = configDir.resolve("$envName.env.secrets.properties")
    if (defaults.exists()) defaults.inputStream().use(props::load)
    if (secrets.exists()) secrets.inputStream().use(props::load)
    return props
}

/** Optional release signing wired purely from environment variables so no
 *  keystore or password is ever committed. Producing a *signed* release
 *  bundle requires all four to be set; otherwise `bundleRelease` falls back
 *  to the debug-signed AAB which is still useful for non-Play distribution.
 *
 *  Required env vars (Play upload-key flow, see docs/implementation/15-google-play-readiness.md):
 *    ANDROID_UPLOAD_KEYSTORE_PATH      — absolute path to the .jks file
 *    ANDROID_UPLOAD_KEYSTORE_PASSWORD  — store password
 *    ANDROID_UPLOAD_KEY_ALIAS          — key alias inside the store
 *    ANDROID_UPLOAD_KEY_PASSWORD       — key password */
data class UploadSigning(
    val storeFile: File,
    val storePassword: String,
    val keyAlias: String,
    val keyPassword: String,
)

fun resolveUploadSigning(): UploadSigning? {
    val path = System.getenv("ANDROID_UPLOAD_KEYSTORE_PATH")?.takeIf { it.isNotBlank() } ?: return null
    val storePassword = System.getenv("ANDROID_UPLOAD_KEYSTORE_PASSWORD")?.takeIf { it.isNotBlank() } ?: return null
    val keyAlias = System.getenv("ANDROID_UPLOAD_KEY_ALIAS")?.takeIf { it.isNotBlank() } ?: return null
    val keyPassword = System.getenv("ANDROID_UPLOAD_KEY_PASSWORD")?.takeIf { it.isNotBlank() } ?: return null
    val resolved = file(path)
    if (!resolved.exists()) return null
    return UploadSigning(resolved, storePassword, keyAlias, keyPassword)
}

android {
    namespace = "ca.roadsense.ns"
    compileSdk = 34

    buildFeatures {
        buildConfig = true
        compose = true
    }

    defaultConfig {
        applicationId = "ca.roadsense.android"
        minSdk = 33
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // Echo versionName into BuildConfig so `clientAppVersion` headers can
        // mirror the Info.plist-derived string iOS sends.
        buildConfigField("String", "APP_VERSION_NAME", "\"0.1.0\"")
        buildConfigField("int", "APP_VERSION_CODE", "1")
        // True only when Mapbox's private Maven was reachable at sync time.
        // The Compose `MapHost` reads this to decide whether to inflate a real
        // MapView or the WebView-based public-map fallback.
        val mapboxAvailable = (rootProject.extra.has("mapboxAvailable") &&
            rootProject.extra["mapboxAvailable"] as Boolean)
        buildConfigField("boolean", "MAPBOX_AVAILABLE", mapboxAvailable.toString())
    }

    flavorDimensions += "environment"

    productFlavors {
        fun com.android.build.api.dsl.ApplicationProductFlavor.applyEnv(envName: String) {
            dimension = "environment"
            val props = loadEnvProperties(envName)
            fun str(key: String, default: String = "") =
                "\"${(props.getProperty(key) ?: default).replace("\"", "\\\"")}\""
            buildConfigField("String", "APP_ENV", str("APP_ENV", envName.uppercase()))
            buildConfigField("String", "API_BASE_URL", str("API_BASE_URL"))
            buildConfigField("String", "MAPBOX_ACCESS_TOKEN", str("MAPBOX_ACCESS_TOKEN"))
            buildConfigField("String", "SUPABASE_ANON_KEY", str("SUPABASE_ANON_KEY"))
            buildConfigField("String", "SENTRY_DSN", str("SENTRY_DSN"))
            buildConfigField(
                "boolean",
                "ENABLE_POTHOLE_PHOTOS",
                (props.getProperty("ENABLE_POTHOLE_PHOTOS") ?: "true"),
            )
            resValue("string", "app_name", props.getProperty("APP_DISPLAY_NAME") ?: "RoadSense NS")
        }

        create("local") {
            applyEnv("local")
            applicationIdSuffix = ".localdebug"
        }
        create("staging") {
            applyEnv("staging")
            applicationIdSuffix = ".staging"
        }
        create("production") {
            applyEnv("production")
            // No suffix on production — applicationId is `ca.roadsense.android`.
        }
    }

    signingConfigs {
        // Only registered when env vars are present; otherwise the default
        // (debug-signed) keystore is used. This keeps CI green without ever
        // committing an upload key, and lets a release machine produce a
        // Play-acceptable AAB just by exporting the four ANDROID_UPLOAD_* vars.
        resolveUploadSigning()?.let { signing ->
            create("upload") {
                storeFile = signing.storeFile
                storePassword = signing.storePassword
                keyAlias = signing.keyAlias
                keyPassword = signing.keyPassword
            }
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
        }
        release {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfigs.findByName("upload")?.let { signingConfig = it }
        }
    }

    composeOptions {
        // Tied to Kotlin 2.0.21 + plugin.compose; no separate compiler version
        // is required because the Compose compiler ships as a Kotlin plugin.
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            isReturnDefaultValues = true
        }
    }

    sourceSets {
        getByName("androidTest").assets.srcDir("$projectDir/schemas")
        getByName("test").resources.srcDir("$rootDir/core-fixtures")
    }

    packaging {
        resources {
            excludes += setOf(
                "/META-INF/{AL2.0,LGPL2.1}",
                "/META-INF/LICENSE*",
                "/META-INF/NOTICE*",
            )
        }
    }
}

dependencies {
    implementation(project(":core-api"))
    implementation(project(":core-sensor"))

    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.activity:activity-ktx:1.9.3")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")

    // Compose BOM keeps Foundation/Material3/UI versions aligned without
    // hand-pinning every artifact.
    val composeBom = platform("androidx.compose:compose-bom:2024.10.01")
    implementation(composeBom)
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    // Room
    implementation("androidx.room:room-runtime:2.6.1")
    implementation("androidx.room:room-ktx:2.6.1")
    ksp("androidx.room:room-compiler:2.6.1")

    // Retrofit + OkHttp + serialization converter
    implementation("com.squareup.retrofit2:retrofit:2.11.0")
    implementation("com.squareup.okhttp3:okhttp:5.0.0-alpha.14")
    implementation("com.squareup.okhttp3:logging-interceptor:5.0.0-alpha.14")
    implementation("com.jakewharton.retrofit:retrofit2-kotlinx-serialization-converter:1.0.0")

    // WorkManager
    implementation("androidx.work:work-runtime-ktx:2.9.1")

    // Mapbox Maps SDK — only added when `MAPBOX_DOWNLOADS_TOKEN` is set in
    // the environment / gradle.properties (see `settings.gradle.kts`). Builds
    // without the token still compile because `MapHost` falls back to a
    // WebView pointing at the public web map.
    if (rootProject.extra.has("mapboxAvailable") &&
        rootProject.extra["mapboxAvailable"] as Boolean
    ) {
        implementation("com.mapbox.maps:android:11.7.0")
    }

    // Tests — JUnit 4 because Robolectric's first-class runtime is JUnit 4.
    // Other modules use JUnit 5; the Android `:app` module deliberately
    // stays on 4 to avoid the Robolectric-Jupiter bridge dance.
    testImplementation(kotlin("test-junit"))
    testImplementation("junit:junit:4.13.2")
    testImplementation("androidx.room:room-testing:2.6.1")
    testImplementation("org.robolectric:robolectric:4.13")
    testImplementation("androidx.test:core:1.6.1")
    testImplementation("androidx.test.ext:junit:1.2.1")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8.1")
    testImplementation("com.squareup.okhttp3:mockwebserver:5.0.0-alpha.14")
}

ksp {
    arg("room.schemaLocation", "$projectDir/schemas")
}
