import Foundation

/// Physical unit of a value. Values are always stored in the unprefixed unit
/// (volts, not millivolts); prefixes exist only in `EngineeringNotation`.
public enum MeasurementUnit: Sendable, Hashable {
    case volt, ampere, ohm, farad, hertz, second
    case celsius, fahrenheit, kelvin
    case decibel, dBm, percent
    /// Dimensionless (ratio, counts, PLC).
    case none
    /// User label from `CALCulate:SCALe:UNIT`.
    case custom(String)

    public var symbol: String {
        switch self {
        case .volt: "V"
        case .ampere: "A"
        case .ohm: "Ω"
        case .farad: "F"
        case .hertz: "Hz"
        case .second: "s"
        case .celsius: "°C"
        case .fahrenheit: "°F"
        case .kelvin: "K"
        case .decibel: "dB"
        case .dBm: "dBm"
        case .percent: "%"
        case .none: ""
        case .custom(let label): label
        }
    }

    /// ASCII-only symbol for CSV headers and other plain-text export.
    public var asciiSymbol: String {
        switch self {
        case .ohm: "Ohm"
        case .celsius: "degC"
        case .fahrenheit: "degF"
        default: symbol
        }
    }

    /// Whether SI prefixes make sense (`mV` yes, `m°C` or `kdB` no).
    public var takesPrefix: Bool {
        switch self {
        case .volt, .ampere, .ohm, .farad, .hertz, .second: true
        default: false
        }
    }

    /// Spellings accepted when parsing typed input, longest first.
    var inputSpellings: [String] {
        switch self {
        case .volt: ["volts", "volt", "v"]
        case .ampere: ["amps", "amp", "a"]
        case .ohm: ["ohms", "ohm", "\u{03C9}"]  // Ω (U+03A9) and the ohm sign (U+2126) both lowercase to ω
        case .farad: ["farads", "farad", "f"]
        case .hertz: ["hz"]
        case .second: ["seconds", "second", "sec", "s"]
        case .celsius: ["°c", "degc", "c"]
        case .fahrenheit: ["°f", "degf", "f"]
        case .kelvin: ["k"]
        case .decibel: ["db"]
        case .dBm: ["dbm"]
        case .percent: ["%"]
        case .none: []
        case .custom(let label): [label.lowercased()]
        }
    }
}

/// Display formatting and typed-input parsing with SI prefixes.
///
/// Output always uses "." as the decimal separator regardless of locale, matching the
/// instrument's display and keeping screenshots, exports and the UI consistent.
public enum EngineeringNotation {
    public struct Prefix: Sendable, Equatable {
        public let symbol: String
        public let exponent: Int
    }

    public static let prefixes: [Prefix] = [
        .init(symbol: "p", exponent: -12), .init(symbol: "n", exponent: -9),
        .init(symbol: "µ", exponent: -6), .init(symbol: "m", exponent: -3),
        .init(symbol: "", exponent: 0), .init(symbol: "k", exponent: 3),
        .init(symbol: "M", exponent: 6), .init(symbol: "G", exponent: 9),
    ]

    /// A value split into mantissa text, SI prefix and unit symbol.
    public struct Formatted: Sendable, Equatable {
        public let number: String
        public let prefix: String
        public let unit: String
        /// Prefix + unit, e.g. "mV".
        public var unitText: String { prefix + unit }
        public var text: String { unitText.isEmpty ? number : "\(number) \(unitText)" }
    }

    /// Formats `value` with `significantDigits` total digits, choosing the prefix that
    /// puts the mantissa in 1 ≤ |m| < 1000 (e.g. `0.0000359` V → "35.9000 µV").
    public static func format(_ value: Double, unit: MeasurementUnit, significantDigits: Int = 7) -> Formatted {
        let digits = max(1, min(significantDigits, 15))
        guard value.isFinite else {
            return Formatted(number: value.isNaN ? "---" : (value < 0 ? "-OVLD" : "OVLD"), prefix: "", unit: unit.symbol)
        }
        guard value != 0 else {
            return Formatted(number: fixed(0, decimals: digits - 1), prefix: "", unit: unit.symbol)
        }
        // Round to the requested digits first so 999.99996 becomes 1.000000 k, not 1000.000.
        let magnitude = Int(floor(log10(abs(value))))
        let scale = pow(10.0, Double(digits - 1 - magnitude))
        let rounded = (value * scale).rounded() / scale
        let exponent = rounded == 0 ? magnitude : Int(floor(log10(abs(rounded)) + 1e-12))

        guard unit.takesPrefix else {
            return Formatted(number: fixed(rounded, decimals: max(0, digits - 1 - exponent)), prefix: "", unit: unit.symbol)
        }
        let engineering = Int(floor(Double(exponent) / 3.0)) * 3
        let clamped = min(max(engineering, prefixes.first!.exponent), prefixes.last!.exponent)
        let prefix = prefixes.first { $0.exponent == clamped }!
        let mantissa = rounded / pow(10.0, Double(clamped))
        let decimals = max(0, digits - 1 - (exponent - clamped))
        return Formatted(number: fixed(mantissa, decimals: decimals), prefix: prefix.symbol, unit: unit.symbol)
    }

    public static func string(_ value: Double, unit: MeasurementUnit, significantDigits: Int = 7) -> String {
        format(value, unit: unit, significantDigits: significantDigits).text
    }

    public static func string(_ reading: Reading, unit: MeasurementUnit, significantDigits: Int = 7) -> String {
        string(reading.value, unit: unit, significantDigits: significantDigits)
    }

    /// Compact form for settings such as ranges: no trailing zeros ("100 mV", "1.5 kΩ").
    public static func compact(_ value: Double, unit: MeasurementUnit, significantDigits: Int = 6) -> String {
        let f = format(value, unit: unit, significantDigits: significantDigits)
        var number = f.number
        if number.contains(".") {
            while number.hasSuffix("0") { number.removeLast() }
            if number.hasSuffix(".") { number.removeLast() }
        }
        return f.unitText.isEmpty ? number : "\(number) \(f.unitText)"
    }

    /// Parses typed input such as "100m", "4.7 kΩ", "10uF", "1e-3", "2.5 MHz" into the
    /// base unit. Prefixes are case-sensitive where it matters: `m` is milli, `M` is mega.
    /// Returns nil for anything it does not fully understand rather than guessing.
    public static func parse(_ text: String, unit: MeasurementUnit) -> Double? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if let plain = Double(s) { return plain.isFinite ? plain : nil }

        // Strip a trailing unit, if present.
        let lower = s.lowercased()
        for spelling in unit.inputSpellings where lower.hasSuffix(spelling) {
            let candidate = String(s.dropLast(spelling.count)).trimmingCharacters(in: .whitespaces)
            // "f"/"k"/"m"-like spellings can collide with prefixes; only strip when what
            // remains still parses as number + optional prefix.
            if parseNumberWithPrefix(candidate, allowPrefix: unit.takesPrefix) != nil {
                s = candidate
                break
            }
        }
        return parseNumberWithPrefix(s, allowPrefix: unit.takesPrefix)
    }

    private static func parseNumberWithPrefix(_ text: String, allowPrefix: Bool) -> Double? {
        let s = text.trimmingCharacters(in: .whitespaces)
        if let plain = Double(s) { return plain.isFinite ? plain : nil }
        guard allowPrefix else { return nil }
        let table: [(String, Double)] = [
            ("meg", 1e6), ("p", 1e-12), ("n", 1e-9), ("u", 1e-6), ("µ", 1e-6), ("μ", 1e-6),
            ("m", 1e-3), ("k", 1e3), ("K", 1e3), ("M", 1e6), ("G", 1e9),
        ]
        for (symbol, factor) in table where s.hasSuffix(symbol) {
            let numberPart = String(s.dropLast(symbol.count)).trimmingCharacters(in: .whitespaces)
            if let number = Double(numberPart), number.isFinite { return number * factor }
        }
        return nil
    }

    private static func fixed(_ value: Double, decimals: Int) -> String {
        // %f with an explicit POSIX locale: never localised.
        String(format: "%.\(decimals)f", locale: Locale(identifier: "en_US_POSIX"), value == 0 ? 0 : value)
    }
}
