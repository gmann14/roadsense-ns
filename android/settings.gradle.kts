@file:Suppress("UnstableApiUsage")

pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        mavenCentral()
    }
}

rootProject.name = "roadsense-android"

// Pure-JVM modules. `core-sensor` ships the iOS pipeline ports + parity tests
// (A12-1). `core-api` ships the wire-format DTOs + JSON parity tests against
// the iOS-committed shape (A12-2). The Android `:app` module is added once
// the rest of A12-2 (Room + Retrofit wiring + WorkManager) lands.
include(":core-sensor")
include(":core-api")
