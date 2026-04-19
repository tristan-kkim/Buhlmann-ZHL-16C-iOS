import Foundation

/// Simulates depth sensor data for development / testing without Apple Watch Ultra.
/// Activate via Xcode scheme environment variables:
///   DIVE_SENSOR_MODE=simulator
///   DIVE_SCENARIO=rectangular_30m_20min  (or other scenario name)
public final class SensorSimulator: DepthSensorSource, Sendable {
    public enum Scenario: Sendable {
        case rectangular(depth: Double, bottomMinutes: Double)
        case multiLevel(levels: [(depth: Double, minutes: Double)])
        case fastAscent(depth: Double, rateMPerMin: Double)
        case ceilingViolation
        case freediving(dives: Int, maxDepth: Double, diveDurationSeconds: Double, surfaceIntervalSeconds: Double)
    }

    private let scenario: Scenario
    private let surfacePressure: Double
    private let waterDensity: Double

    public init(
        scenario: Scenario = .rectangular(depth: 30, bottomMinutes: 20),
        surfacePressure: Double = 1.0133,
        waterDensity: Double = 1025.0
    ) {
        self.scenario = scenario
        self.surfacePressure = surfacePressure
        self.waterDensity = waterDensity
    }

    public var pressureStream: AsyncStream<PressureSample> {
        let sp = surfacePressure
        let wd = waterDensity
        let profile = buildProfile()
        return AsyncStream { continuation in
            Task {
                for depthMeters in profile {
                    let pressure = DepthCalculator.pressure(at: depthMeters, surfacePressure: sp, waterDensity: wd)
                    let state: DepthSensorState = depthMeters < 0.5 ? .surface : .submerged
                    continuation.yield(PressureSample(
                        pressure: pressure,
                        surfacePressure: sp,
                        depth: depthMeters > 0 ? depthMeters : nil,
                        sensorState: state
                    ))
                    try? await Task.sleep(for: .milliseconds(100)) // 10 Hz
                }
                continuation.finish()
            }
        }
    }

    private func buildProfile() -> [Double] {
        switch scenario {
        case .rectangular(let depth, let minutes):
            return rectangularProfile(depth: depth, bottomSeconds: minutes * 60)

        case .multiLevel(let levels):
            var profile: [Double] = []
            var current = 0.0
            for level in levels {
                profile += transition(from: current, to: level.depth, rate: 18)
                profile += flat(depth: level.depth, seconds: level.minutes * 60)
                current = level.depth
            }
            profile += transition(from: current, to: 0, rate: 9)
            return profile

        case .fastAscent(let depth, let rate):
            var profile = rectangularProfile(depth: depth, bottomSeconds: 300)
            profile += transition(from: depth, to: 0, rate: rate)
            return profile

        case .ceilingViolation:
            var profile = transition(from: 0, to: 40, rate: 18)
            profile += flat(depth: 40, seconds: 600)
            profile += transition(from: 40, to: 0, rate: 18)
            return profile

        case .freediving(let dives, let maxDepth, let diveSeconds, let surfaceSeconds):
            var profile: [Double] = []
            for _ in 0..<dives {
                profile += transition(from: 0, to: maxDepth, rate: 30)
                profile += flat(depth: maxDepth, seconds: diveSeconds * 0.3)
                profile += transition(from: maxDepth, to: 0, rate: 30)
                profile += flat(depth: 0, seconds: surfaceSeconds)
            }
            return profile
        }
    }

    private func rectangularProfile(depth: Double, bottomSeconds: Double) -> [Double] {
        var profile: [Double] = []
        profile += transition(from: 0, to: depth, rate: 18)
        profile += flat(depth: depth, seconds: bottomSeconds)
        profile += transition(from: depth, to: 5, rate: 9)
        profile += flat(depth: 5, seconds: 180)
        profile += transition(from: 5, to: 0, rate: 9)
        return profile
    }

    private func transition(from: Double, to: Double, rate: Double) -> [Double] {
        let distance = abs(to - from)
        let seconds = (distance / rate) * 60.0
        let samples = Int(seconds * 10)
        guard samples > 0 else { return [] }
        return (0..<samples).map { i in
            let t = Double(i) / Double(samples)
            return from + (to - from) * t
        }
    }

    private func flat(depth: Double, seconds: Double) -> [Double] {
        Array(repeating: depth, count: Int(seconds * 10))
    }
}
