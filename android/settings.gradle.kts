@file:Suppress("UnstableApiUsage")

pluginManagement {
    repositories {
        gradlePluginPortal()
        google()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "roadsense-android"

// Pure-JVM modules. `core-sensor` ships the iOS pipeline ports + parity tests
// (A12-1). `core-api` ships the wire-format DTOs + JSON parity tests against
// the iOS-committed shape (A12-2a). `:app` is the Android module containing
// Room persistence + Retrofit BackendClient (A12-2b); foreground service +
// Compose UI land in A12-3 / A12-4.
include(":core-sensor")
include(":core-api")
include(":app")
