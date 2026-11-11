import Foundation

/// A finished or in-progress set of readings with everything needed to interpret it
/// later: what was measured, in which unit, how it was timed and how the meter was set.
public struct Recording: Sendable, Codable, Identifiable, Equatable {
    public enum Timing: Sendable, Codable, Equatable {
        /// Paced by the meter's sample timer: sample `i` was taken `i × interval`
        /// seconds after the first. Exact to the meter's timebase.
        case meterPaced(interval: Double)
        /// Timed by the app as readings arrived over the network; `times` holds the
        /// offsets. Good to a few milliseconds, not for timing analysis.
        case appTimed
    }

    /// One labelled setting captured when the recording started, e.g. ("Range", "10 V").
    public struct SettingNote: Sendable, Codable, Equatable {
        public let label: String
        public let value: String
        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public var id = UUID()
    public var name: String
    public var instrument: InstrumentIdentity
    public var function: MeasurementFunction
    /// Unit of `values`. Always the unprefixed unit (V, not mV).
    public var unit: MeasurementUnit
    public var timing: Timing
    /// When the first sample was taken (as closely as the app knows).
    public var started: Date
    public var settings: [SettingNote]
    /// Readings in base units. Overload is ±infinity, an invalid reading is NaN.
    public var values: [Double]
    /// Seconds since `started` for each value; empty when `timing` is meter-paced.
    public var times: [Double]

    public init(
        name: String, instrument: InstrumentIdentity, function: MeasurementFunction, unit: MeasurementUnit,
        timing: Timing, started: Date, settings: [SettingNote] = [], values: [Double] = [], times: [Double] = []
    ) {
        self.name = name
        self.instrument = instrument
        self.function = function
        self.unit = unit
        self.timing = timing
        self.started = started
        self.settings = settings
        self.values = values
        self.times = times
    }

    public var count: Int { values.count }

    /// Seconds from the first sample to sample `index`.
    public func time(at index: Int) -> Double {
        switch timing {
        case .meterPaced(let interval): Double(index) * interval
        case .appTimed: index < times.count ? times[index] : .nan
        }
    }

    public var duration: Double { count > 0 ? time(at: count - 1) : 0 }

    public var statistics: RunningStatistics {
        var stats = RunningStatistics()
        for value in values { stats.add(Reading(decoded: value)) }
        return stats
    }

    public mutating func append(_ readings: [Reading]) {
        values.append(contentsOf: readings.map(\.value))
    }

    public mutating func append(_ reading: Reading, at date: Date) {
        values.append(reading.value)
        times.append(date.timeIntervalSince(started))
    }
}

extension Reading {
    /// Rebuilds a reading from a stored value (±infinity is overload, NaN is invalid).
    public init(decoded value: Double) {
        if value.isNaN {
            self.init(raw: SCPIValue.notANumber)
        } else if value.isInfinite {
            self.init(raw: value < 0 ? -SCPIValue.overloadMagnitude : SCPIValue.overloadMagnitude)
        } else {
            self.init(raw: value)
        }
    }
}
