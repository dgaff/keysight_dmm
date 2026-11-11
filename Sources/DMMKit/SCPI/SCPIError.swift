import Foundation

/// One entry from the instrument's error queue (`SYSTem:ERRor?`).
public struct InstrumentError: Sendable, Equatable, Hashable, CustomStringConvertible {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    /// Parses a `SYST:ERR?` response such as `-113,"Undefined header"` or `+0,"No error"`.
    public init?(response: String) {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comma = trimmed.firstIndex(of: ","),
              let code = Int(trimmed[..<comma].trimmingCharacters(in: .whitespaces)) else { return nil }
        var text = String(trimmed[trimmed.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        self.code = code
        self.message = text
    }

    public var description: String { "\(code > 0 ? "+" : "")\(code), \"\(message)\"" }
}

public enum SCPIError: Error, Sendable, Equatable, LocalizedError {
    /// The TCP connection could not be established. On this bench that is very often a
    /// firewall (Little Snitch) rule rather than a bug, so the UI should say so.
    case connectionFailed(String)
    case connectionLost(String)
    case notConnected
    case timeout(command: String)
    case malformedResponse(command: String, response: String)
    /// The instrument queued one or more errors in response to `command`.
    case instrument([InstrumentError], command: String)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let why): "Could not connect to the instrument: \(why)"
        case .connectionLost(let why): "The connection to the instrument was lost: \(why)"
        case .notConnected: "Not connected to an instrument."
        case .timeout(let command): "The instrument did not answer \"\(command)\" in time."
        case .malformedResponse(let command, let response):
            "Unexpected response to \"\(command)\": \(response.prefix(80))"
        case .instrument(let errors, let command):
            "The instrument rejected \"\(command)\": " + errors.map(\.description).joined(separator: "; ")
        }
    }
}
