import Foundation

public struct LocationSample: Equatable, Sendable {
    public let timestamp: TimeInterval
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracyMeters: Double
    public let speedKmh: Double
    public let headingDegrees: Double

    public init(
        timestamp: TimeInterval,
        latitude: Double,
        longitude: Double,
        horizontalAccuracyMeters: Double,
        speedKmh: Double,
        headingDegrees: Double
    ) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.speedKmh = speedKmh
        self.headingDegrees = headingDegrees
    }
}

public struct ReadingWindow: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let roughnessRMS: Double
    public let speedKmh: Double
    public let headingDegrees: Double
    public let gpsAccuracyMeters: Double
    public let startedAt: TimeInterval
    public let durationSeconds: TimeInterval
    public let sampleCount: Int
    public let potholeSpikeCount: Int
    public let potholeMaxG: Double

    public init(
        latitude: Double,
        longitude: Double,
        roughnessRMS: Double,
        speedKmh: Double,
        headingDegrees: Double,
        gpsAccuracyMeters: Double,
        startedAt: TimeInterval,
        durationSeconds: TimeInterval,
        sampleCount: Int,
        potholeSpikeCount: Int,
        potholeMaxG: Double
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.roughnessRMS = roughnessRMS
        self.speedKmh = speedKmh
        self.headingDegrees = headingDegrees
        self.gpsAccuracyMeters = gpsAccuracyMeters
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.sampleCount = sampleCount
        self.potholeSpikeCount = potholeSpikeCount
        self.potholeMaxG = potholeMaxG
    }
}

public struct ReadingBuilder: Sendable {
    public var targetDistanceMeters: Double = 40
    public var maxDurationSeconds: TimeInterval = 15
    public var maxHorizontalAccuracyMeters: Double = 20
    public var maxHeadingVarianceDegrees: Double = 60
    public var minimumSampleCount: Int = 30

    private var locationSamples: [LocationSample] = []
    private var motionSamples: [MotionSample] = []

    public init() {}

    public mutating func addMotionSample(_ sample: MotionSample) {
        motionSamples.append(sample)
    }

    public mutating func addLocationSample(_ sample: LocationSample) -> ReadingWindow? {
        guard sample.horizontalAccuracyMeters <= maxHorizontalAccuracyMeters else {
            reset()
            return nil
        }

        if locationSamples.isEmpty {
            locationSamples = [sample]
            return nil
        }

        locationSamples.append(sample)

        let duration = sample.timestamp - locationSamples[0].timestamp
        guard duration <= maxDurationSeconds else {
            reset(startingWith: sample)
            return nil
        }

        guard headingVarianceDegrees(for: locationSamples) <= maxHeadingVarianceDegrees else {
            reset(startingWith: sample)
            return nil
        }

        guard traveledDistanceMeters(for: locationSamples) >= targetDistanceMeters else {
            return nil
        }

        guard motionSamples.count >= minimumSampleCount else {
            reset(startingWith: sample)
            return nil
        }

        let reading = ReadingWindow(
            latitude: midpoint(for: locationSamples).latitude,
            longitude: midpoint(for: locationSamples).longitude,
            roughnessRMS: rms(of: motionSamples),
            speedKmh: averageSpeed(for: locationSamples),
            headingDegrees: weightedHeading(for: locationSamples),
            gpsAccuracyMeters: locationSamples.map(\.horizontalAccuracyMeters).max() ?? sample.horizontalAccuracyMeters,
            startedAt: locationSamples[0].timestamp,
            durationSeconds: duration,
            sampleCount: motionSamples.count,
            potholeSpikeCount: 0,
            potholeMaxG: 0
        )

        reset(startingWith: sample)
        return reading
    }

    private mutating func reset(startingWith sample: LocationSample? = nil) {
        locationSamples = sample.map { [$0] } ?? []
        motionSamples = []
    }

    private func rms(of samples: [MotionSample]) -> Double {
        let meanSquare = samples.reduce(0.0) { partialResult, sample in
            let value = sample.verticalAcceleration
            return partialResult + (value * value)
        } / Double(samples.count)

        return sqrt(meanSquare)
    }

    private func averageSpeed(for samples: [LocationSample]) -> Double {
        samples.map(\.speedKmh).reduce(0, +) / Double(samples.count)
    }

    private func midpoint(for samples: [LocationSample]) -> (latitude: Double, longitude: Double) {
        let totalDistance = traveledDistanceMeters(for: samples)
        let target = totalDistance / 2

        guard totalDistance > 0, samples.count > 1 else {
            let sample = samples[samples.count / 2]
            return (sample.latitude, sample.longitude)
        }

        var traversed = 0.0

        for index in 1..<samples.count {
            let previous = samples[index - 1]
            let current = samples[index]
            let segmentDistance = distanceMeters(from: previous, to: current)

            if traversed + segmentDistance >= target, segmentDistance > 0 {
                let progress = (target - traversed) / segmentDistance
                return (
                    latitude: previous.latitude + ((current.latitude - previous.latitude) * progress),
                    longitude: previous.longitude + ((current.longitude - previous.longitude) * progress)
                )
            }

            traversed += segmentDistance
        }

        let last = samples.last!
        return (last.latitude, last.longitude)
    }

    private func traveledDistanceMeters(for samples: [LocationSample]) -> Double {
        guard samples.count > 1 else {
            return 0
        }

        return zip(samples, samples.dropFirst()).reduce(0.0) { partialResult, pair in
            partialResult + distanceMeters(from: pair.0, to: pair.1)
        }
    }

    private func distanceMeters(from lhs: LocationSample, to rhs: LocationSample) -> Double {
        let earthRadiusMeters = 6_371_000.0
        let lat1 = lhs.latitude * .pi / 180
        let lat2 = rhs.latitude * .pi / 180
        let deltaLat = (rhs.latitude - lhs.latitude) * .pi / 180
        let deltaLon = (rhs.longitude - lhs.longitude) * .pi / 180

        let a = sin(deltaLat / 2) * sin(deltaLat / 2) +
            cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))

        return earthRadiusMeters * c
    }

    private func weightedHeading(for samples: [LocationSample]) -> Double {
        let weights = samples.map { max($0.speedKmh, 0.1) }
        let x = zip(samples, weights).reduce(0.0) { partialResult, pair in
            partialResult + cos(pair.0.headingDegrees * .pi / 180) * pair.1
        }
        let y = zip(samples, weights).reduce(0.0) { partialResult, pair in
            partialResult + sin(pair.0.headingDegrees * .pi / 180) * pair.1
        }

        let angle = atan2(y, x) * 180 / .pi
        return angle >= 0 ? angle : angle + 360
    }

    private func headingVarianceDegrees(for samples: [LocationSample]) -> Double {
        let mean = weightedHeading(for: samples)

        return samples.reduce(0.0) { partialResult, sample in
            max(partialResult, angularDistanceDegrees(from: sample.headingDegrees, to: mean))
        }
    }

    private func angularDistanceDegrees(from lhs: Double, to rhs: Double) -> Double {
        let raw = abs(lhs - rhs).truncatingRemainder(dividingBy: 360)
        return min(raw, 360 - raw)
    }
}
