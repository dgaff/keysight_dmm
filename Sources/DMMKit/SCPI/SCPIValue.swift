import Foundation

/// Encoding and decoding of SCPI parameter and response values.
///
/// Everything here is locale-independent: Swift's `Double(String)` and `"\(Double)"`
/// always use "." and never group digits, unlike `NumberFormatter`/`String(format:)`
/// with a locale.
public enum SCPIValue {
    /// IEEE 488.2 / SCPI sentinel the meter returns for an overload ("OVLD"): ±9.9E37.
    public static let overloadMagnitude = 9.9e37
    /// SCPI "not a number" sentinel.
    public static let notANumber = 9.91e37

    /// Formats a number as a bare SCPI numeric parameter in SI base units, with enough
    /// digits to round-trip. Never appends a unit suffix: SCPI suffix parsing is where
    /// prefix bugs live (`MA` is milliamps but `MOHM` and `MHZ` are mega).
    public static func number(_ value: Double) -> String {
        precondition(value.isFinite, "SCPI numeric parameters must be finite")
        return "\(value)"
    }

    public static func bool(_ value: Bool) -> String { value ? "ON" : "OFF" }

    /// Quotes a string parameter, doubling embedded quotes.
    public static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func parseDouble(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func parseInt(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = Int(trimmed) { return i }
        // Some integer settings come back in exponent form, e.g. "+1.00000000E+03".
        if let d = Double(trimmed), d.isFinite, d == d.rounded(), abs(d) < 9e15 { return Int(d) }
        return nil
    }

    /// Accepts `1`/`0` (what the instrument returns) and `ON`/`OFF`.
    public static func parseBool(_ text: String) -> Bool? {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "1", "ON": true
        case "0", "OFF": false
        default: nil
        }
    }

    /// Strips the surrounding quotes from a string response and un-doubles embedded quotes.
    public static func parseString(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            s = String(s.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
        }
        return s
    }

    /// Parses a comma-separated list of numbers (e.g. `FETC?`, ASCII `R?` payload).
    public static func parseDoubleList(_ text: String) -> [Double]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        var out: [Double] = []
        for field in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
            guard let v = Double(field.trimmingCharacters(in: .whitespaces)) else { return nil }
            out.append(v)
        }
        return out
    }

    /// Decodes a `FORMat:DATA REAL,64` payload: IEEE 754 doubles, big-endian with
    /// `FORMat:BORDer NORMal` (the default), little-endian with `SWAPped`.
    public static func parseReal64(_ data: Data, bigEndian: Bool = true) -> [Double]? {
        guard data.count % 8 == 0 else { return nil }
        var out = [Double]()
        out.reserveCapacity(data.count / 8)
        data.withUnsafeBytes { raw in
            for offset in stride(from: 0, to: raw.count, by: 8) {
                let bits = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                out.append(Double(bitPattern: bigEndian ? UInt64(bigEndian: bits) : UInt64(littleEndian: bits)))
            }
        }
        return out
    }
}

/// One measurement value in SI base units, with the SCPI sentinels decoded.
public struct Reading: Sendable, Equatable, Hashable {
    public enum Status: Sendable, Equatable, Hashable {
        case valid
        /// The input exceeded the range (meter shows OVERLOAD); `value` is ±infinity.
        case overload
        /// The meter returned the SCPI NaN sentinel; `value` is NaN.
        case invalid
    }

    public let value: Double
    public let status: Status

    public init(raw: Double) {
        if raw.isNaN || abs(raw - SCPIValue.notANumber) < 1e30 {
            value = .nan
            status = .invalid
        } else if abs(raw) >= SCPIValue.overloadMagnitude * 0.999 {
            value = raw < 0 ? -.infinity : .infinity
            status = .overload
        } else {
            value = raw
            status = .valid
        }
    }

    public init?(response: String) {
        guard let raw = SCPIValue.parseDouble(response) else { return nil }
        self.init(raw: raw)
    }

    public var isValid: Bool { status == .valid }
}
