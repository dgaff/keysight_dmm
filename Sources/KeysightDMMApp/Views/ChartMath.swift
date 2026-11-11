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

    /// Times and values of what a chart plots, in SI base units.
    struct Series: Sendable, Equatable {
        /// Seconds since the first sample.
        var times: [Double] = []
        var values: [Double] = []
        var count: Int { values.count }

        init() {}
        init(times: [Double], values: [Double]) {
            self.times = times
            self.values = values
        }

        init(samples: [Sample]) {
            guard let origin = samples.first?.time else { return }
            times = samples.map { $0.time.timeIntervalSince(origin) }
            values = samples.map { $0.reading.value }
        }

        init(recording: Recording) {
            values = recording.values
            times = (0..<recording.count).map { recording.time(at: $0) }
        }
    }

    /// Nice axis tick positions, all printed with the same number of decimals.
    struct Ticks: Sendable, Equatable {
        var values: [Double] = []
        var decimals = 0
    }

    /// Keeps finite readings only and reduces them to roughly `maxPoints` points. Each
    /// bucket contributes its minimum and maximum (in time order) so spikes survive.
    static func decimate(_ series: Series, maxPoints: Int = 2_000) -> [Point] {
        var valid: [Int] = []
        valid.reserveCapacity(series.count)
        for i in 0..<series.count where series.values[i].isFinite && i < series.times.count && series.times[i].isFinite {
            valid.append(i)
        }
        func point(_ i: Int) -> Point { Point(id: i, seconds: series.times[i], value: series.values[i]) }
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
            for i in valid[start..<end] {
                if series.values[i] < series.values[low] { low = i }
                if series.values[i] > series.values[high] { high = i }
            }
            if low == high {
                result.append(point(low))
            } else if low < high {
                result.append(point(low)); result.append(point(high))
            } else {
                result.append(point(high)); result.append(point(low))
            }
        }
        return result
    }

    /// Tick positions (1, 2 or 5 times a power of ten) covering `range`, and the number
    /// of decimals that tells adjacent ticks apart.
    static func ticks(in range: ClosedRange<Double>, desired: Int = 5) -> Ticks {
        let span = range.upperBound - range.lowerBound
        guard span.isFinite, span > 0 else { return Ticks(values: [range.lowerBound], decimals: 3) }
        let raw = span / Double(max(desired, 1))
        let exponent = floor(log10(raw))
        let fraction = raw / pow(10, exponent)
        let nice: Double = fraction < 1.5 ? 1 : (fraction < 3 ? 2 : (fraction < 7 ? 5 : 10))
        let step = nice * pow(10, exponent)
        let first = (range.lowerBound / step - 1e-9).rounded(.up)
        let last = (range.upperBound / step + 1e-9).rounded(.down)
        guard last >= first, last - first <= 40 else { return Ticks(values: [range.lowerBound], decimals: 3) }
        let values = (Int(first)...Int(last)).map { Double($0) * step }
        let decimals = max(0, Int(-(nice == 10 ? exponent + 1 : exponent)))
        return Ticks(values: values, decimals: min(decimals, 14))
    }

    /// A tick value written with exactly `decimals` decimals, through `EngineeringNotation`.
    static func tickLabel(_ value: Double, decimals: Int) -> String {
        let scale = pow(10, Double(decimals))
        let rounded = (value * scale).rounded() / scale
        if rounded == 0 { return EngineeringNotation.format(0, unit: .none, significantDigits: decimals + 1).number }
        let exponent = Int(floor(log10(abs(rounded)) + 1e-12))
        let digits = min(15, max(1, exponent + 1 + decimals))
        return EngineeringNotation.format(rounded, unit: .none, significantDigits: digits).number
    }

    /// Divisor and unit text for an elapsed-time axis that runs to `maxSeconds`.
    static func timeAxis(maxSeconds: Double) -> (divisor: Double, unit: String) {
        if maxSeconds >= 7200 { return (3600, "h") }
        if maxSeconds >= 120 { return (60, "min") }
        if maxSeconds >= 1 || !maxSeconds.isFinite || maxSeconds <= 0 { return (1, "s") }
        let scale = axisScale(maxMagnitude: maxSeconds, unit: .second)
        return (scale.divisor, scale.prefix + "s")
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

    /// Equal-width bins over the finite values.
    static func histogram(values all: [Double], binCount: Int = 30) -> [Bin] {
        var values: [Double] = []
        values.reserveCapacity(all.count)
        for v in all where v.isFinite { values.append(v) }
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
