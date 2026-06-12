plugins {
    kotlin("jvm")
}

kotlin {
    jvmToolchain(21)
}

sourceSets {
    test {
        // The CSV+JSON fixtures are shared with iOS bit-for-bit and live in
        // android/core-fixtures/. Adding them as a test-resources source dir
        // means tests load them via Class.getResourceAsStream("/pothole-hit.csv")
        // without having to copy the tree into core-sensor/src/test/resources/.
        resources.srcDir("$rootDir/core-fixtures")
    }
}

dependencies {
    testImplementation(kotlin("test-junit5"))
    testImplementation("org.junit.jupiter:junit-jupiter:5.10.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.test {
    useJUnitPlatform()
}
