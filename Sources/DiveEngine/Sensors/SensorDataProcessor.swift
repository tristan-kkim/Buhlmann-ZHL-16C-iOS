import Foundation

/// Mirrors CMWaterSubmersionMeasurement.DepthState without importing CoreMotion in DiveEngine.
public enum DepthSensorState: Sendable {
    case surface           // Not submerged (depth < ~1 m)
    case submerged         // Normal diving
    case approachingMaxDepth // Near hardware depth limit (~38 m)
    case pastMaxDepth      // Exceeded hardware depth limit — CRITICAL
    case sensorIssue       // Hardware sensor problem
    case unknown
}

/// A single raw sample from the depth sensor.
public struct PressureSample: Sendable {
    /// Ambient (absolute) pressure in bar.
    public let pressure: Double
    /// Atmospheric surface pressure in bar — updates dynamically with altitude / weather.
    public let surfacePressure: Double
    /// Depth in meters as provided directly by Apple's sensor (nil when not submerged).
    /// Preferred over pressure-derived depth for display accuracy.
    public let depth: Double?
    /// Hardware depth sensor state from CMWaterSubmersionMeasurement.depthState.
    public let sensorState: DepthSensorState

    public init(
        pressure: Double,
        surfacePressure: Double,
        depth: Double? = nil,
        sensorState: DepthSensorState = .unknown
    ) {
        self.pressure = pressure
        self.surfacePressure = surfacePressure
        self.depth = depth
        self.sensorState = sensorState
    }
}

/// Protocol abstracting the depth sensor source (real CMWaterSubmersionManager or simulator).
public protocol DepthSensorSource: Sendable {
    var pressureStream: AsyncStream<PressureSample> { get }
}

/// Processes raw sensor data: applies median filter, buckets to 1 Hz, converts to depth.
/// Uses Apple's direct `.depth` measurement when available; falls back to pressure formula.
/// Tracks dynamic surface pressure for accurate altitude / weather-compensated depth.
public actor SensorDataProcessor {
    private let source: any DepthSensorSource
    private let waterDensity: Double

    private var rawWindow: [Double] = []
    private let windowSize = 5
    private var bucketSamples: [Double] = []
    private var lastBucketTime: Date = .now
    private var currentSurfacePressure: Double = 1.0133
    private var lastDirectDepth: Double? = nil      // Apple's direct depth
    private var lastSensorState: DepthSensorState = .unknown

    public typealias DepthHandler = @Sendable (Double, DepthSensorState) async -> Void
    private var depthHandler: DepthHandler?

    public init(source: some DepthSensorSource, waterDensity: Double = 1025.0) {
        self.source = source
        self.waterDensity = waterDensity
    }

    /// Start processing. Calls `handler` approximately once per second with validated depth (m)
    /// and the current sensor state.
    public func start(handler: @escaping DepthHandler) {
        self.depthHandler = handler
        Task { [weak self] in
            guard let self else { return }
            for await sample in await self.source.pressureStream {
                await self.process(sample: sample)
            }
        }
    }

    private func process(sample: PressureSample) async {
        currentSurfacePressure = sample.surfacePressure
        lastDirectDepth = sample.depth
        lastSensorState = sample.sensorState

        // 1. Median filter on raw ambient pressure
        rawWindow.append(sample.pressure)
        if rawWindow.count > windowSize { rawWindow.removeFirst() }
        let filtered = median(of: rawWindow)

        // 2. Bucket into 1 Hz
        bucketSamples.append(filtered)
        let now = Date()
        guard now.timeIntervalSince(lastBucketTime) >= 1.0 else { return }
        lastBucketTime = now

        let avgPressure = bucketSamples.reduce(0, +) / Double(bucketSamples.count)
        bucketSamples.removeAll()

        // 3. Depth: prefer Apple's direct value; fallback to pressure formula
        let depth: Double
        if let d = lastDirectDepth, d > 0 {
            depth = d
        } else {
            depth = DepthCalculator.depth(
                from: avgPressure,
                surfacePressure: currentSurfacePressure,
                waterDensity: waterDensity
            )
        }

        await depthHandler?(depth, lastSensorState)
    }

    private func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0
            ? (sorted[mid - 1] + sorted[mid]) / 2.0
            : sorted[mid]
    }
}
