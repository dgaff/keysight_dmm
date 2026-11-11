import DMMKit
import Foundation

/// Bench validation: drives a Keysight 33500-series waveform generator wired to the
/// meter's HI/LO input and checks what DMMKit reads back.
///
/// The point is less the meter's accuracy (Keysight calibrates that) than ours: units
/// and prefixes across ranges, sample timing, triggering, math. A prefix mistake shows
/// up as an error of 1000×, far outside these tolerances, which are set by the
/// generator's own accuracy (about 1 % of setting + 2 mV).
///
/// Stays within ±5 V. Both instruments' setups are saved to a state file first and
/// restored afterwards, and the generator's output is left off.
struct Bench {
    let meter: Multimeter
    let generator: SCPISession
    var passed = 0
    var failed = 0

    static let stateFile = "INT:\\dmmprobe_bench.sta"

    mutating func check(_ name: String, _ measured: Double, expected: Double, tolerance: Double, unit: MeasurementUnit) {
        let ok = measured.isFinite && abs(measured - expected) <= tolerance
        if ok { passed += 1 } else { failed += 1 }
        let m = EngineeringNotation.string(measured, unit: unit, significantDigits: 6)
        let e = EngineeringNotation.string(expected, unit: unit, significantDigits: 4)
        let t = EngineeringNotation.string(tolerance, unit: unit, significantDigits: 2)
        print("  \(ok ? "PASS" : "FAIL")  \(name.padding(toLength: 34, withPad: " ", startingAt: 0)) read \(m), expected \(e) ± \(t)")
    }

    mutating func check(_ name: String, _ condition: Bool, _ detail: String) {
        if condition { passed += 1 } else { failed += 1 }
        print("  \(condition ? "PASS" : "FAIL")  \(name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(detail)")
    }

    func gen(_ command: String) async throws {
        try await generator.set(command)
    }

    func dc(_ volts: Double) async throws {
        try await gen("FUNC DC")
        try await gen("VOLT:OFFS \(SCPIValue.number(volts))")
    }

    func sine(frequency: Double, rms: Double) async throws {
        try await gen("FUNC SIN")
        try await gen("VOLT:OFFS 0")
        try await gen("FREQ \(SCPIValue.number(frequency))")
        try await gen("VOLT:UNIT VRMS")
        try await gen("VOLT \(SCPIValue.number(rms))")
    }

    /// Lets the source and the meter's autoranging settle, then returns a fresh reading.
    func settledReading(discard: Int = 1) async throws -> Double {
        try await Task.sleep(for: .milliseconds(400))
        for _ in 0..<discard { _ = try await meter.read(timeout: .seconds(30)) }
        return try await meter.read(timeout: .seconds(30)).value
    }

    func set(_ function: MeasurementFunction, _ id: String, _ value: SettingValue) async throws {
        guard let setting = FunctionProfile.profile(for: function).setting(id) else { return }
        try await meter.apply(setting, value)
    }

    func auto(_ function: MeasurementFunction, _ id: String, _ mode: AutoMode) async throws {
        guard let setting = FunctionProfile.profile(for: function).setting(id) else { return }
        try await meter.setAuto(setting, mode)
    }

    func collect(_ plan: AcquisitionPlan) async throws -> (values: [Double], info: AcquisitionInfo?, end: AcquisitionEnd?) {
        var values: [Double] = []
        var info: AcquisitionInfo?
        var end: AcquisitionEnd?
        for try await event in meter.acquire(plan).events {
            switch event {
            case .started(let i): info = i
            case .readings(let batch): values += batch.map(\.value)
            case .finished(let e, _): end = e
            }
        }
        return (values, info, end)
    }

    mutating func run() async throws {
        let generatorID = try await generator.query("*IDN?")
        print("Meter:     \(meter.identity.model) s/n \(meter.identity.serialNumber)")
        print("Generator: \(generatorID)")

        // Save both setups; restore them whatever happens.
        try await meter.storeState(to: Self.stateFile)
        try await generator.set("MMEM:STOR:STAT \"\(Self.stateFile)\"")
        do {
            try await gen("OUTP OFF")
            try await gen("OUTP:LOAD INF")  // the meter's input is high impedance: amplitudes are as set
            try await dc(0)
            try await gen("OUTP ON")
            try await tests()
        } catch {
            failed += 1
            print("  FAIL  stopped by an error: \(error.localizedDescription)")
        }
        _ = try? await generator.write("OUTP OFF")
        _ = try? await generator.write("MMEM:LOAD:STAT \"\(Self.stateFile)\"")
        _ = try? await generator.write("OUTP OFF")
        _ = try? await generator.write("MMEM:DEL \"\(Self.stateFile)\"")
        _ = try? await generator.drainErrors()
        _ = try? await meter.loadState(from: Self.stateFile)
        _ = try? await meter.deleteFile(Self.stateFile)
        _ = try? await meter.session.drainErrors()
        print("\n\(passed) passed, \(failed) failed. Both instruments' setups were restored; the generator output is off.")
    }

    private mutating func tests() async throws {
        print("\nDC voltage, autorange (units across the 100 mV, 1 V and 10 V ranges)")
        try await meter.setFunction(.dcVoltage)
        try await auto(.dcVoltage, "range", .on)
        try await set(.dcVoltage, "nplc", .number(1))
        for volts in [-5.0, -1, -0.1, 0, 0.01, 0.1, 1, 5] {
            try await dc(volts)
            let reading = try await settledReading(discard: 2)
            check("DCV \(EngineeringNotation.compact(volts, unit: .volt))", reading, expected: volts, tolerance: abs(volts) * 0.01 + 0.003, unit: .volt)
        }

        print("\nDC voltage, each fixed range reading the same 50 mV (range must not change the value)")
        try await dc(0.05)
        for range in [0.1, 1, 10, 100, 1000] {
            try await set(.dcVoltage, "range", .number(range))
            let reading = try await settledReading()
            // Resolution falls with range: allow for it on the 100 V and 1000 V ranges.
            check("50 mV on \(EngineeringNotation.compact(range, unit: .volt)) range", reading, expected: 0.05, tolerance: 0.004 + range * 2e-5, unit: .volt)
        }
        try await auto(.dcVoltage, "range", .on)

        print("\ndBm scaling (1 V into 600 Ω is 2.218 dBm)")
        try await dc(1)
        try await set(.dcVoltage, "scalingFunction", .choice("DBM"))
        try await set(.dcVoltage, "dbmReference", .number(600))
        try await set(.dcVoltage, "scaling", .bool(true))
        check("1 V as dBm", try await settledReading(discard: 2), expected: 10 * log10(1.0 / 600 / 1e-3), tolerance: 0.15, unit: .dBm)
        try await set(.dcVoltage, "scaling", .bool(false))

        print("\nAC voltage, 1 kHz sine, autorange")
        try await meter.setFunction(.acVoltage)
        for rms in [0.01, 0.1, 1, 3] {
            try await sine(frequency: 1000, rms: rms)
            let reading = try await settledReading(discard: 2)
            check("ACV \(EngineeringNotation.compact(rms, unit: .volt)) rms", reading, expected: rms, tolerance: rms * 0.02 + 0.001, unit: .volt)
        }

        print("\nAC voltage with frequency as the secondary measurement")
        try await sine(frequency: 1000, rms: 1)
        try await set(.acVoltage, "secondary", .choice("FREQ"))
        try await Task.sleep(for: .milliseconds(500))
        // The frequency secondary is only refreshed on some readings; take the first that has one.
        var both = try await meter.readWithSecondary(timeout: .seconds(30))
        for _ in 0..<4 where both.secondary == nil {
            both = try await meter.readWithSecondary(timeout: .seconds(30))
        }
        check("primary (V rms)", both.primary.value, expected: 1, tolerance: 0.021, unit: .volt)
        check("secondary (Hz)", both.secondary?.value ?? .nan, expected: 1000, tolerance: 0.5, unit: .hertz)
        try await meter.setFunction(.dcVoltage)
        try await auto(.dcVoltage, "range", .on)
        try await set(.dcVoltage, "secondary", .choice("PTP"))
        try await Task.sleep(for: .milliseconds(500))
        both = try await meter.readWithSecondary(timeout: .seconds(30))
        for _ in 0..<4 where both.secondary == nil {
            both = try await meter.readWithSecondary(timeout: .seconds(30))
        }
        check("DCV peak-to-peak secondary", both.secondary?.value ?? .nan, expected: 2 * 2.0.squareRoot(), tolerance: 0.06, unit: .volt)
        try await set(.dcVoltage, "secondary", .choice("OFF"))
        try await meter.setFunction(.acVoltage)
        try await set(.acVoltage, "secondary", .choice("OFF"))

        print("\nFrequency and period, 1 V rms sine")
        for frequency in [100.0, 1_000, 10_000, 100_000] {
            try await sine(frequency: frequency, rms: 1)
            try await meter.setFunction(.frequency)
            check("frequency \(EngineeringNotation.compact(frequency, unit: .hertz))", try await settledReading(), expected: frequency, tolerance: frequency * 2e-4, unit: .hertz)
            try await meter.setFunction(.period)
            check("period of \(EngineeringNotation.compact(frequency, unit: .hertz))", try await settledReading(), expected: 1 / frequency, tolerance: 2e-4 / frequency, unit: .second)
        }

        print("\nMeter-paced sampling of a 10 Hz sine (sample timing)")
        try await sine(frequency: 10, rms: 1)
        try await meter.setFunction(.dcVoltage)
        try await set(.dcVoltage, "range", .number(10))
        let applied = try await meter.applyFastestSamplingPreset()
        check("fastest-sampling preset", applied.count == 4, applied.joined(separator: "; "))
        let timed = try await collect(AcquisitionPlan(pacing: .interval(0.001), stop: .samples(2000)))
        check("run completed", timed.end == .completed && timed.values.count == 2000, "\(timed.values.count) samples, ended \(String(describing: timed.end))")
        check("interval as requested", timed.info?.interval ?? .nan, expected: 0.001, tolerance: 2e-6, unit: .second)
        let rms = (timed.values.map { $0 * $0 }.reduce(0, +) / Double(max(timed.values.count, 1))).squareRoot()
        check("rms of the samples", rms, expected: 1, tolerance: 0.03, unit: .volt)
        // 2 s of a 10 Hz sine has 20 rising zero crossings; ±1 for where the window starts.
        let crossings = zip(timed.values, timed.values.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        check("rising zero crossings in 2 s", Double(crossings), expected: 20, tolerance: 1, unit: .none)

        print("\nLevel trigger with pre-trigger samples")
        let plan = AcquisitionPlan(
            pacing: .interval(0.001), stop: .samples(500), trigger: .level(0.5, rising: true), pretriggerSamples: 100)
        let triggered = try await collect(plan)
        // The meter returns fewer pre-trigger samples if the trigger comes early: 400 to 500 in all.
        let count = triggered.values.count
        check("run completed", triggered.end == .completed && (400...500).contains(count), "\(count) samples, ended \(String(describing: triggered.end))")
        if let at = plan.triggerIndex(total: count, expected: 500), at >= 10, at + 10 < count {
            check("trigger index", true, "trigger at sample \(at) of \(count)")
            // At 10 Hz and 1.414 V peak the signal moves about 85 mV per 1 ms sample near 0.5 V,
            // so the sample at the trigger point should sit within a couple of steps of the level.
            check("sample at the trigger point", triggered.values[at], expected: 0.5, tolerance: 0.2, unit: .volt)
            check("rising through the level", triggered.values[at - 10] < 0.5 && triggered.values[at + 10] > 0.5,
                  "10 samples before: \(EngineeringNotation.compact(triggered.values[at - 10], unit: .volt)), 10 after: \(EngineeringNotation.compact(triggered.values[at + 10], unit: .volt))")
        } else {
            check("trigger index", false, "could not locate the trigger in \(count) samples")
        }
    }
}
