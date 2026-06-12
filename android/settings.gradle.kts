@file:Suppress("UnstableApiUsage")

import org.gradle.api.GradleException

pluginManagement {
    repositories {
        gradlePluginPortal()
        google()
        mavenCentral()
    }
}

/**
 * Mapbox Maps SDK ships through a private Maven hosted at
 * api.mapbox.com/downloads/v2/releases/maven and requires a `MAPBOX_DOWNLOADS_TOKEN`
 * for resolution. We register the repo only when the token is present so a
 * developer or CI runner without it (the public-repo default) can still build
 * the entire project. Builds with the token expose a `mapboxAvailable` extra
 * that `:app/build.gradle.kts` switches the optional Mapbox dependency on.
 */
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    val mapboxToken = providers.environmentVariable("MAPBOX_DOWNLOADS_TOKEN")
        .orElse(providers.gradleProperty("MAPBOX_DOWNLOADS_TOKEN"))
        .orNull
        ?.takeIf { it.isNotBlank() }
    gradle.rootProject {
        extensions.extraProperties.set("mapboxAvailable", mapboxToken != null)
    }
    repositories {
        google()
        mavenCentral()
        if (mapboxToken != null) {
            maven {
                url = uri("https://api.mapbox.com/downloads/v2/releases/maven")
                authentication {
                    create<BasicAuthentication>("basic")
                }
                credentials {
                    username = "mapbox"
                    password = mapboxToken
                }
            }
        }
    }
}

rootProject.name = "roadsense-android"

// Pure-JVM modules. `core-sensor` ships the iOS pipeline ports + parity tests
// (A12-1). `core-api` ships the wire-format DTOs + JSON parity tests against
// the iOS-committed shape (A12-2a). `:app` is the Android module containing
// Room persistence + Retrofit BackendClient (A12-2b), Compose UI, manual
// pothole flow, feedback queue, and the Mapbox map shell (A12-3..A12-5).
include(":core-sensor")
include(":core-api")
include(":app")
