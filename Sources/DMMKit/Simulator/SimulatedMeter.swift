import Foundation

/// An in-process stand-in for a 34470A, used by unit tests, SwiftUI previews and the
/// app's demo mode so UI work does not need the bench.
///
/// It is deliberately simple: commands are matched on the exact short-form spelling
/// DMMKit sends (upper case, e.g. `VOLT:NPLC`). Headers listed in
/// `SimulatedMeterDefaults.swift` behave like the real meter: they answer with factory
/// defaults, answer `MIN`/`MAX`/`DEF` queries, validate and normalise what is set, and
/// reject out-of-range numbers with -222. Any other `HEADER value` is stored and echoed
/// back by `HEADER?`. Queries with no stored or default value queue -113 and send
/// nothing, like the real meter (the caller then sees a timeout).
public final class SimulatedMeter: SCPITransport, @unchecked Sendable {
    public let inbox = ByteInbox()
    public let endpointDescription = "Simulated 34470A"

    private let lock = NSLock()
    private var settings: [String: String]
    private var errors: [String] = []
    private var connected = false
    /// Every command line received, for assertions in tests.
    public private(set) var received: [String] = []
    /// Headers that should swallow their response, to exercise timeout handling.
    public var unresponsiveQueries: Set<String> = []
    /// Value the simulated input sits at for each function (base units).
    public var inputs: [String: Double] = [
        "VOLT": 1.234_567_8, "VOLT:AC": 0.707_106_8, "CURR": 0.012_345_6, "CURR:AC": 0.005,
        "RES": 9_998.76, "FRES": 9_998.71, "FREQ": 1_000.012, "PER": 0.000_999_988,
        "CAP": 1.02e-7, "TEMP": 23.45, "CONT": 2.1, "DIOD": 0.612, "VOLT:RAT": 0.5,
    ]
    public var noiseFraction = 2e-6

    /// A run started by `INIT`: readings become available as simulated time passes.
    private struct Run {
        var started: Date
        var interval: Double
        var count: Int
        var delivered = 0
        /// Set by `ABOR`: no readings after this many.
        var cappedAt: Int?

        func taken(at now: Date) -> Int {
            let elapsed = now.timeIntervalSince(started)
            let byTime = elapsed < 0 ? 0 : Int(elapsed / interval) + 1
            return min(count, cappedAt ?? .max, byTime)
        }
    }
    private var run: Run?

    public static let idn = "Keysight Technologies,34470A,SIM0000001,A.03.03-03.15-03.03-00.52-05-02"

    public init() {
        settings = [
            "FUNC": "\"VOLT\"",
            "SYST:VERS": "1994.0",
            "*OPT": "0,0,0,0,0",
            "FORM:DATA": "ASC,9",
            "UNIT:TEMP": "C",
        ]
    }

    public func connect(timeout: Duration) async throws(SCPIError) {
        lock.withLock { connected = true }
    }

    public func close() async {
        lock.withLock { connected = false }
        inbox.fail(.notConnected)
    }

    public func send(_ data: Data) async throws(SCPIError) {
        guard lock.withLock({ connected }) else { throw .notConnected }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            var responses: [Data] = []
            lock.withLock {
                received.append(String(line))
                for command in line.split(separator: ";") {
                    let trimmed = command.trimmingCharacters(in: .whitespaces)
                    if let block = handleReadingMemory(trimmed) {
                        responses.append(block)
                    } else if let response = handle(trimmed) {
                        responses.append(Data(response.utf8))
                    }
                }
            }
            if !responses.isEmpty {
                let out = Data(responses.joined(separator: Data(";".utf8))) + Data([0x0A])
                // A measurement takes its integration time, as on the real meter.
                let upper = line.uppercased()
                let delay = upper.contains("READ?") || upper.contains("MEAS") ? lock.withLock { measurementTime() } : 0
                if delay > 0 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [inbox] in inbox.append(out) }
                } else {
                    inbox.append(out)
                }
            }
        }
    }

    /// Queues an error as the instrument would, e.g. to test error surfacing.
    public func injectError(_ code: Int, _ message: String) {
        lock.withLock { errors.append("\(code),\"\(message)\"") }
    }

    /// `R? [max]`: removes readings from the simulated memory and returns them as a
    /// definite-length block in the current `FORM:DATA`. Called with the lock held.
    private func handleReadingMemory(_ command: String) -> Data? {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        guard let head = parts.first?.uppercased(), head == "R?" || head == ":R?" else { return nil }
        var available = 0
        if var current = run {
            available = current.taken(at: Date()) - current.delivered
            if parts.count > 1, let limit = Int(parts[1]) { available = min(available, limit) }
            current.delivered += available
            run = current
        }
        let values = (0..<available).map { _ in simulatedReading() }
        var payload = Data()
        if (settings["FORM:DATA"] ?? "ASC,9").hasPrefix("REAL") {
            let swapped = settings["FORM:BORD"] == "SWAP"
            for value in values {
                let bits = swapped ? value.bitPattern.littleEndian : value.bitPattern.bigEndian
                withUnsafeBytes(of: bits) { payload.append(contentsOf: $0) }
            }
        } else {
            payload = Data(values.map(Self.formatNumber).joined(separator: ",").utf8)
        }
        let length = String(payload.count)
        return Data("#\(length.count)\(length)".utf8) + payload
    }

    // Called with the lock held.
    private func handle(_ command: String) -> String? {
        guard !command.isEmpty else { return nil }
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        var header = parts[0].uppercased()
        if header.hasPrefix(":") { header.removeFirst() }
        if header.hasPrefix("SENS:") { header.removeFirst(5) }
        let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil

        if header.hasSuffix("?") {
            let key = String(header.dropLast())
            if unresponsiveQueries.contains(key) { return nil }
            switch key {
            case "*IDN": return Self.idn
            case "SYST:ERR": return errors.isEmpty ? "+0,\"No error\"" : errors.removeFirst()
            case "*OPC": return "1"
            case "*STB", "*ESR": return "+0"
            case "STAT:OPER:COND":
                guard let run else { return "+0" }
                return run.taken(at: Date()) < min(run.count, run.cappedAt ?? .max) ? "+16" : "+0"
            case "DATA:POIN":
                return "+\(run.map { $0.taken(at: Date()) - $0.delivered } ?? 0)"
            case "READ", "MEAS", "FETC": return formatted(simulatedReading())
            default:
                let canonical = Self.canonical(key)
                if let argument, let entry = Self.defaults[canonical] {
                    switch argument.uppercased() {
                    case "MIN" where entry.min != nil: return Self.formatNumber(entry.min ?? 0)
                    case "MAX" where entry.max != nil: return Self.formatNumber(entry.max ?? 0)
                    case "DEF": return entry.value
                    default:
                        errors.append("-224,\"Illegal parameter value\"")
                        return nil
                    }
                }
                if let value = settings[canonical] ?? Self.defaults[canonical]?.value { return value }
                errors.append("-113,\"Undefined header\"")
                return nil
            }
        }

        switch header {
        case "*CLS":
            errors.removeAll()
        case "*RST", "SYST:PRES":
            settings["FUNC"] = "\"VOLT\""
            settings = settings.filter { Self.defaults[$0.key] == nil }
        case "ABOR":
            if var current = run {
                current.cappedAt = current.taken(at: Date())
                run = current
            }
        case "INIT":
            func number(_ key: String, _ fallback: Double) -> Double {
                SCPIValue.parseDouble(settings[key] ?? Self.defaults[key]?.value ?? "") ?? fallback
            }
            let timed = (settings["SAMP:SOUR"] ?? "IMM") == "TIM"
            run = Run(started: Date(), interval: timed ? number("SAMP:TIM", 1) : 0.01,
                      count: Int(number("SAMP:COUN", 1)) * Int(min(number("TRIG:COUN", 1), 1e6)))
        case "SYST:LOC", "SYST:REM", "*TRG", "*WAI":
            break
        case "FUNC":
            if let argument, let function = MeasurementFunction(scpiResponse: argument) {
                settings["FUNC"] = "\"\(function.scpi)\""
            } else {
                errors.append("-224,\"Illegal parameter value\"")
            }
        default:
            guard let argument else {
                errors.append("-113,\"Undefined header\"")
                return nil
            }
            let key = Self.canonical(header)
            if let entry = Self.defaults[key] {
                store(argument, for: key, like: entry)
            } else {
                settings[key] = argument
            }
        }
        return nil
    }

    /// Validates `argument` against a known setting and stores it in the form the meter
    /// answers with. Queues an error and changes nothing if it does not fit.
    /// Called with the lock held.
    private func store(_ argument: String, for key: String, like entry: DefaultEntry) {
        let token = argument.uppercased()
        let stored: String
        if entry.min != nil || entry.max != nil {
            let number: Double?
            switch token {
            case "MIN": number = entry.min
            case "MAX": number = entry.max
            case "DEF": number = SCPIValue.parseDouble(entry.value)
            default: number = SCPIValue.parseDouble(argument)
            }
            guard let number, number.isFinite else {
                errors.append("-104,\"Data type error\"")
                return
            }
            let slack = abs(number) * 1e-12
            if let low = entry.min, number < low - slack {
                errors.append("-222,\"Data out of range\"")
                return
            }
            if let high = entry.max, number > high + slack {
                errors.append("-222,\"Data out of range\"")
                return
            }
            stored = Self.formatNumber(number)
            // Fixing a range or null value switches the matching automatic mode off.
            let autoKey = key + ":AUTO"
            if key.hasSuffix(":RANG") || key.hasSuffix(":VAL"), Self.defaults[autoKey] != nil {
                settings[autoKey] = "0"
            }
            // NPLC and aperture time are alternatives; the last one sent wins.
            if key.hasSuffix(":NPLC") || key.hasSuffix(":APER") {
                let modeKey = key.split(separator: ":").dropLast().joined(separator: ":") + ":APER:ENAB"
                if Self.defaults[modeKey] != nil { settings[modeKey] = key.hasSuffix(":APER") ? "1" : "0" }
            }
        } else if entry.value == "0" || entry.value == "1" {
            switch token {
            case "ON", "1": stored = "1"
            case "OFF", "0", "ONCE": stored = "0"
            default:
                errors.append("-224,\"Illegal parameter value\"")
                return
            }
        } else if entry.value.hasPrefix("\"") {
            guard argument.hasPrefix("\""), argument.hasSuffix("\""), argument.count >= 2 else {
                errors.append("-151,\"Invalid string data\"")
                return
            }
            stored = "\"" + MeterSetting.shortForm(of: SCPIValue.parseString(argument).uppercased()) + "\""
        } else {
            guard token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == ":" }) else {
                errors.append("-224,\"Illegal parameter value\"")
                return
            }
            stored = MeterSetting.shortForm(of: token)
        }
        settings[key] = stored
    }

    /// Multiplies simulated measurement time; 0 makes `READ?` answer immediately (tests).
    public var timeScale = 1.0

    /// Seconds one reading takes with the current function's NPLC and auto zero (60 Hz line).
    /// Called with the lock held.
    private func measurementTime() -> Double {
        let function = Self.canonical(SCPIValue.parseString(settings["FUNC"] ?? "\"VOLT\""))
        func value(_ key: String) -> String? { settings[key] ?? Self.defaults[key]?.value }
        guard let nplc = value("\(function):NPLC").flatMap(SCPIValue.parseDouble) else { return 0.1 * timeScale }
        let aperture = value("\(function):APER:ENAB") == "1"
            ? (value("\(function):APER").flatMap(SCPIValue.parseDouble) ?? 0.1) : nplc / 60
        let autoZero = value("\(function):ZERO:AUTO") != "0"
        return (aperture * (autoZero ? 2 : 1) + 0.002) * timeScale
    }

    private func simulatedReading() -> Double {
        let function = SCPIValue.parseString(settings["FUNC"] ?? "\"VOLT\"")
        let nominal = inputs[function] ?? 0
        return nominal * (1 + Double.random(in: -1...1) * noiseFraction)
    }

    private func formatted(_ value: Double) -> String { Self.formatNumber(value) }
}
