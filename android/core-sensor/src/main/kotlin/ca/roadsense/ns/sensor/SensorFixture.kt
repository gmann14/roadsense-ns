package ca.roadsense.ns.sensor

import java.time.Instant
import java.time.format.DateTimeParseException

sealed class SensorFixtureEvent {
    abstract val timestampEpochSeconds: Double

    data class Gps(override val timestampEpochSeconds: Double, val sample: LocationSample) : SensorFixtureEvent()
    data class Accel(override val timestampEpochSeconds: Double, val userAcceleration: MotionVector3) : SensorFixtureEvent()
    data class Gravity(override val timestampEpochSeconds: Double, val gravity: MotionVector3) : SensorFixtureEvent()
    data class Thermal(override val timestampEpochSeconds: Double, val state: ThermalCollectionState) : SensorFixtureEvent()
    data class Activity(override val timestampEpochSeconds: Double, val isAutomotive: Boolean) : SensorFixtureEvent()
}

data class SensorFixture(val events: List<SensorFixtureEvent>)

sealed class SensorFixtureParseError(message: String) : RuntimeException(message) {
    data object Empty : SensorFixtureParseError("fixture is empty")
    data object InvalidHeader : SensorFixtureParseError("fixture header is invalid")
    data class InvalidColumnCount(val line: Int) : SensorFixtureParseError("fixture line $line must have between 3 and 7 columns")
    data class NonMonotonicTimestamp(val line: Int) : SensorFixtureParseError("fixture timestamp is not strictly monotonic at line $line")
    data class InvalidTimestamp(val line: Int) : SensorFixtureParseError("fixture timestamp is invalid at line $line")
    data class InvalidType(val line: Int, val value: String) : SensorFixtureParseError("fixture type '$value' is invalid at line $line")
    data class InvalidNumber(val line: Int, val column: Int) : SensorFixtureParseError("fixture numeric value at line $line, column $column is invalid")
    data class InvalidThermalState(val line: Int, val value: String) : SensorFixtureParseError("fixture thermal value '$value' is invalid at line $line")
}

object SensorFixtureParser {
    private const val EXPECTED_HEADER = "timestamp,type,value1,value2,value3,value4,value5"

    fun parse(csv: String): SensorFixture {
        val normalized = csv.replace("\r\n", "\n")
        val lines = normalized.split('\n')

        if (lines.isEmpty()) throw SensorFixtureParseError.Empty
        if (lines[0] != EXPECTED_HEADER) throw SensorFixtureParseError.InvalidHeader

        val events = mutableListOf<SensorFixtureEvent>()
        var previousTimestampEpoch: Double? = null

        lines.drop(1).forEachIndexed { index, line ->
            val lineNumber = index + 2
            if (line.isEmpty()) return@forEachIndexed

            val rawColumns = line.split(',')
            if (rawColumns.size < 3 || rawColumns.size > 7) {
                throw SensorFixtureParseError.InvalidColumnCount(lineNumber)
            }
            val padded = rawColumns + List(maxOf(0, 7 - rawColumns.size)) { "" }

            val instant = try {
                Instant.parse(padded[0])
            } catch (_: DateTimeParseException) {
                throw SensorFixtureParseError.InvalidTimestamp(lineNumber)
            }
            val timestamp = instant.toEpochMilli().toDouble() / 1000.0
            val previous = previousTimestampEpoch
            if (previous != null && timestamp <= previous) {
                throw SensorFixtureParseError.NonMonotonicTimestamp(lineNumber)
            }
            previousTimestampEpoch = timestamp

            val type = padded[1]
            val event: SensorFixtureEvent = when (type) {
                "gps" -> SensorFixtureEvent.Gps(
                    timestampEpochSeconds = timestamp,
                    sample = LocationSample(
                        timestamp = timestamp,
                        latitude = parseDouble(padded[2], lineNumber, 3),
                        longitude = parseDouble(padded[3], lineNumber, 4),
                        horizontalAccuracyMeters = parseDouble(padded[6], lineNumber, 7),
                        speedKmh = parseDouble(padded[4], lineNumber, 5),
                        headingDegrees = parseDouble(padded[5], lineNumber, 6),
                    ),
                )

                "accel" -> SensorFixtureEvent.Accel(
                    timestampEpochSeconds = timestamp,
                    userAcceleration = MotionVector3(
                        x = parseDouble(padded[2], lineNumber, 3),
                        y = parseDouble(padded[3], lineNumber, 4),
                        z = parseDouble(padded[4], lineNumber, 5),
                    ),
                )

                "gravity" -> SensorFixtureEvent.Gravity(
                    timestampEpochSeconds = timestamp,
                    gravity = MotionVector3(
                        x = parseDouble(padded[2], lineNumber, 3),
                        y = parseDouble(padded[3], lineNumber, 4),
                        z = parseDouble(padded[4], lineNumber, 5),
                    ),
                )

                "thermal" -> SensorFixtureEvent.Thermal(
                    timestampEpochSeconds = timestamp,
                    state = thermalState(padded[2])
                        ?: throw SensorFixtureParseError.InvalidThermalState(lineNumber, padded[2]),
                )

                "activity" -> SensorFixtureEvent.Activity(
                    timestampEpochSeconds = timestamp,
                    isAutomotive = padded[2] == "automotive",
                )

                else -> throw SensorFixtureParseError.InvalidType(lineNumber, type)
            }

            events.add(event)
        }

        if (events.isEmpty()) throw SensorFixtureParseError.Empty
        return SensorFixture(events = events)
    }

    private fun parseDouble(value: String, line: Int, column: Int): Double =
        value.toDoubleOrNull() ?: throw SensorFixtureParseError.InvalidNumber(line, column)

    private fun thermalState(rawValue: String): ThermalCollectionState? = when (rawValue) {
        "0" -> ThermalCollectionState.NOMINAL
        "1" -> ThermalCollectionState.FAIR
        "2" -> ThermalCollectionState.SERIOUS
        "3" -> ThermalCollectionState.CRITICAL
        else -> null
    }
}
