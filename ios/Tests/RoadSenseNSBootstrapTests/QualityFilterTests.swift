import Foundation
import Testing

@testable import RoadSenseNSBootstrap

@Suite("Quality filter")
struct QualityFilterTests {
    @Test("accepts a reading inside all documented thresholds")
    func acceptsValidReading() {
        let decision = QualityFilter.evaluate(
            reading: makeReading(),
            deviceState: DeviceCollectionState(thermalState: .nominal, isLowPowerModeEnabled: false)
        )

        #expect(decision == .accepted)
    }

    @Test("rejects when gps accuracy exceeds 20 meters")
    func rejectsPoorGPSAccuracy() {
        let decision = QualityFilter.evaluate(
            reading: makeReading(gpsAccuracyMeters: 21),
            deviceState: DeviceCollectionState(thermalState: .nominal, isLowPowerModeEnabled: false)
        )

        #expect(decision == .rejected(.gpsAccuracy))
    }

    @Test("rejects when speed is below the floor")
    func rejectsLowSpeed() {
        let decision = QualityFilter.evaluate(
            reading: makeReading(speedKmh: 10),
            deviceState: DeviceCollectionState(thermalState: .nominal, isLowPowerModeEnabled: false)
        )

        #expect(decision == .rejected(.speed))
    }

    @Test("rejects when speed is above the ceiling")
    func rejectsHighSpeed() {
        let decision = QualityFilter.evaluate(
            reading: makeReading(speedKmh: 170),
            deviceState: DeviceCollectionState(thermalState: .nominal, isLowPowerModeEnabled: false)
        )

        #expect(decision == .rejected(.speed))
    }

    @Test("rejects when sample count is too low")
    func rejectsLowSampleCount() {
        let decision = QualityFilter.evaluate(
            reading: makeReading(sampleCount: 20),
            deviceState: DeviceCollectionState(thermalState: .nominal, isLowPowerModeEnabled: false)
        )

        #expect(decision == .rejected(.sampleCount))
    }

    @Test("rejects when duration exceeds 15 seconds")
    func rejectsLongDuration() {
        let decision = QualityFilter.evaluate(
            reading: makeReading(durationSeconds: 16),
            deviceState: DeviceCollectionState(thermalState: .nominal, isLowPowerModeEnabled: false)
        )

        #expect(decision == .rejected(.duration))
    }

    @Test("rejects when thermal state is serious")
    func rejectsSeriousThermalState() {
        let decision = QualityFilter.evaluate(
            reading: makeReading(),
            deviceState: DeviceCollectionState(thermalState: .serious, isLowPowerModeEnabled: false)
        )

        #expect(decision == .rejected(.thermal))
    }

    @Test("low power mode does not reject the reading")
    func lowPowerModeDoesNotReject() {
        let decision = QualityFilter.evaluate(
            reading: makeReading(),
            deviceState: DeviceCollectionState(thermalState: .nominal, isLowPowerModeEnabled: true)
        )

        #expect(decision == .accepted)
    }

    private func makeReading(
        speedKmh: Double = 45,
        gpsAccuracyMeters: Double = 5,
        durationSeconds: TimeInterval = 10,
        sampleCount: Int = 40
    ) -> ReadingWindow {
        ReadingWindow(
            latitude: 44.6488,
            longitude: -63.5752,
            roughnessRMS: 0.8,
            speedKmh: speedKmh,
            headingDegrees: 10,
            gpsAccuracyMeters: gpsAccuracyMeters,
            startedAt: 0,
            durationSeconds: durationSeconds,
            sampleCount: sampleCount,
            potholeSpikeCount: 0,
            potholeMaxG: 0
        )
    }
}
