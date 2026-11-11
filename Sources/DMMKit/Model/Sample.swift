import Foundation

/// A reading with the time the app received it.
public struct Sample: Sendable, Equatable, Identifiable {
    public let index: Int
    public let time: Date
    public let reading: Reading
    public var id: Int { index }

    public init(index: Int, time: Date, reading: Reading) {
        self.index = index
        self.time = time
        self.reading = reading
    }
}

/// Incremental min / max / mean / standard deviation (Welford's method), so statistics
/// over long runs do not need the samples kept. Overload and invalid readings are
/// counted separately and excluded from the numbers.
public struct RunningStatistics: Sendable, Equatable {
    public private(set) var count = 0
    public private(set) var excluded = 0
    public private(set) var minimum = Double.infinity
    public private(set) var maximum = -Double.infinity
    public private(set) var mean = 0.0
    private var sumSquaredDeviations = 0.0

    public init() {}

    public mutating func add(_ reading: Reading) {
        guard reading.isValid else {
            excluded += 1
            return
        }
        let x = reading.value
        count += 1
        minimum = min(minimum, x)
        maximum = max(maximum, x)
        let delta = x - mean
        mean += delta / Double(count)
        sumSquaredDeviations += delta * (x - mean)
    }

    /// Sample standard deviation (n − 1); nil with fewer than two readings.
    public var standardDeviation: Double? {
        count > 1 ? (sumSquaredDeviations / Double(count - 1)).squareRoot() : nil
    }

    public var peakToPeak: Double? { count > 0 ? maximum - minimum : nil }
    public var isEmpty: Bool { count == 0 }
}
