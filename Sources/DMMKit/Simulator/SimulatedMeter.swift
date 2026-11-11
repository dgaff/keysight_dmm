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
            var responses: [String] = []
            lock.withLock {
                received.append(String(line))
                for command in line.split(separator: ";") {
                    if let response = handle(command.trimmingCharacters(in: .whitespaces)) {
                        responses.append(response)
                    }
                }
            }
            if !responses.isEmpty {
                inbox.append(Data((responses.joined(separator: ";") + "\n").utf8))
            }
        }
    }

    /// Queues an error as the instrument would, e.g. to test error surfacing.
    public func injectError(_ code: Int, _ message: String) {
        lock.withLock { errors.append("\(code),\"\(message)\"") }
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
        case "SYST:LOC", "SYST:REM", "ABOR", "INIT", "*TRG", "*WAI":
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

    private func simulatedReading() -> Double {
        let function = SCPIValue.parseString(settings["FUNC"] ?? "\"VOLT\"")
        let nominal = inputs[function] ?? 0
        return nominal * (1 + Double.random(in: -1...1) * noiseFraction)
    }

    private func formatted(_ value: Double) -> String { Self.formatNumber(value) }
}
