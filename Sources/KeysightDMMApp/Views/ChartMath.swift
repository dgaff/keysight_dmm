import DMMKit
import Foundation

/// Pure helpers behind the Measure chart: decimation, axis scaling and histogram
/// binning. No UI types, so they can be unit-tested.
enum ChartMath {
    struct Point: Identifiable, Sendable, Equatable {
        let id: Int
        /// Seconds since the first plotted sample.
        let seconds: Double
        /// Value in SI base units.
        let value: Double
    }

    struct Bin: Identifiable, Sendable, Equatable {
        let id: Int
        let lower: Double
        let upper: Double
        let count: Int
    }

    /// One SI prefix chosen for a whole axis.
    struct AxisScale: Sendable, Equatable {
        let prefix: String
        /// Divide base-unit values by this to get axis values.
        let divisor: Double

        static let identity = AxisScale(prefix: "", divisor: 1)

        func scaled(_ value: Double) -> Double { value / divisor }
    }

    /// Keeps valid readings only and reduces them to roughly `maxPoints` points. Each
    /// bucket contributes its minimum and maximum (in time order) so spikes survive.
    static func decimate(samples: [Sample], maxPoints: Int = 2_000) -> [Point] {
        guard let origin = samples.first?.time else { return [] }
        let valid = samples.filter { $0.reading.isValid }
        func point(_ s: Sample) -> Point {
            Point(id: s.index, seconds: s.time.timeIntervalSince(origin), value: s.reading.value)
        }
        guard valid.count > maxPoints, maxPoints >= 4 else { return valid.map(point) }

        let buckets = maxPoints / 2
        var result: [Point] = []
        result.reserveCapacity(maxPoints + 2)
        for bucket in 0..<buckets {
            let start = bucket * valid.count / buckets
            let end = (bucket + 1) * valid.count / buckets
            guard start < end else { continue }
            var low = valid[start]
            var high = valid[start]
            for s in valid[start..<end] {
                if s.reading.value < low.reading.value { low = s }
                if s.reading.value > high.reading.value { high = s }
            }
            if low.index == high.index {
                result.append(point(low))
            } else if low.index < high.index {
                result.append(point(low)); result.append(point(high))
            } else {
                result.append(point(high)); result.append(point(low))
            }
        }
        return result
    }

    /// Picks one SI prefix for an axis from the largest magnitude shown.
    static func axisScale(maxMagnitude: Double, unit: MeasurementUnit) -> AxisScale {
        guard unit.takesPrefix, maxMagnitude.isFinite, maxMagnitude > 0 else { return .identity }
        let prefix = EngineeringNotation.format(maxMagnitude, unit: unit, significantDigits: 3).prefix
        guard let match = EngineeringNotation.prefixes.first(where: { $0.symbol == prefix }) else { return .identity }
        return AxisScale(prefix: prefix, divisor: pow(10, Double(match.exponent)))
    }

    /// A y range that always has some height, padded a little so the line does not
    /// touch the frame.
    static func paddedRange(low: Double, high: Double) -> ClosedRange<Double> {
        guard low.isFinite, high.isFinite else { return 0...1 }
        if high - low < Double.ulpOfOne * max(1, abs(high)) * 8 {
            let pad = max(abs(high) * 0.01, 1e-12)
            return (low - pad)...(high + pad)
        }
        let pad = (high - low) * 0.08
        return (low - pad)...(high + pad)
    }

    /// Equal-width bins over the valid values.
    static func histogram(samples: [Sample], binCount: Int = 30) -> [Bin] {
        var values: [Double] = []
        values.reserveCapacity(samples.count)
        for s in samples where s.reading.isValid { values.append(s.reading.value) }
        guard let low = values.min(), let high = values.max() else { return [] }
        if low == high {
            let pad = max(abs(low) * 0.001, 1e-12)
            return [Bin(id: 0, lower: low - pad, upper: high + pad, count: values.count)]
        }
        let bins = max(1, binCount)
        let width = (high - low) / Double(bins)
        var counts = [Int](repeating: 0, count: bins)
        for v in values {
            counts[min(bins - 1, Int((v - low) / width))] += 1
        }
        return counts.enumerated().map { i, c in
            Bin(id: i, lower: low + Double(i) * width, upper: low + Double(i + 1) * width, count: c)
        }
    }
}
