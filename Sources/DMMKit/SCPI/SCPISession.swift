import Foundation

/// One line of SCPI traffic, for the in-app console and for debugging.
public struct SCPITrafficEvent: Sendable {
    public enum Direction: Sendable { case sent, received, note }
    public let date: Date
    public let direction: Direction
    public let text: String
}

public enum SCPIResponse: Sendable, Equatable {
    case text(String)
    case block(Data)
}

/// Serialises command/response exchanges with one instrument.
///
/// Every public operation takes the session lock, so callers on different tasks (a live
/// polling loop and a settings change, say) never interleave bytes on the wire. Use
/// `exclusive` to run several steps as one uninterrupted sequence.
///
/// Conventions (see docs/DECISIONS.md):
/// - Commands are sent exactly as given, LF-terminated. Numbers must already be bare
///   SI base-unit values (`SCPIValue.number`); unit suffixes are never sent.
/// - After a timeout the session is "desynced": the next operation first discards any
///   late bytes. The instrument itself drops an unread response when a new command
///   arrives (and queues -410 "Query INTERRUPTED").
public actor SCPISession {
    public nonisolated let transport: any SCPITransport
    public var defaultTimeout: Duration = .seconds(5)

    private var busy = false
    private var lockWaiters: [CheckedContinuation<Void, Never>] = []
    private var desynced = false
    private var trafficHandler: (@Sendable (SCPITrafficEvent) -> Void)?

    public init(transport: any SCPITransport) {
        self.transport = transport
    }

    public func setDefaultTimeout(_ timeout: Duration) { defaultTimeout = timeout }

    public func setTrafficHandler(_ handler: (@Sendable (SCPITrafficEvent) -> Void)?) {
        trafficHandler = handler
    }

    // MARK: Locked, single-step operations

    /// Sends a command without checking the error queue.
    public func write(_ command: String) async throws {
        try await exclusive { try await $0.rawWrite(command) }
    }

    /// Sends a query and returns the response line, trimmed.
    public func query(_ command: String, timeout: Duration? = nil) async throws -> String {
        try await exclusive { try await $0.rawQuery(command, timeout: timeout) }
    }

    /// Sends a query whose response is an IEEE 488.2 definite-length block and returns the payload.
    public func queryBlock(_ command: String, timeout: Duration? = nil) async throws -> Data {
        try await exclusive { try await $0.rawQueryBlock(command, timeout: timeout) }
    }

    /// Sends a command, then reads the error queue; throws `SCPIError.instrument` if the
    /// instrument objected. Use this for every setting change.
    public func set(_ command: String) async throws {
        try await exclusive { try await $0.rawSet(command) }
    }

    /// Sends a query that this instrument may not support. Returns nil, with the error
    /// queue cleared, if the meter stays silent or queues an error; other failures throw.
    /// An unknown header gets no response at all, so keep `timeout` short when probing.
    public func queryIfSupported(_ command: String, timeout: Duration? = nil) async throws -> String? {
        try await exclusive { s in
            do {
                let response = try await s.rawQuery(command, timeout: timeout)
                return try await s.rawDrainErrors().isEmpty ? response : nil
            } catch SCPIError.timeout {
                _ = try await s.rawDrainErrors()
                return nil
            }
        }
    }

    /// Reads and clears the instrument's error queue.
    public func drainErrors() async throws -> [InstrumentError] {
        try await exclusive { try await $0.rawDrainErrors() }
    }

    // MARK: Exclusive sequences

    /// Runs `body` with the session lock held. Inside, use only the `raw…` methods.
    public func exclusive<T: Sendable>(
        _ body: @Sendable (isolated SCPISession) async throws -> T
    ) async throws -> T {
        await acquire()
        defer { release() }
        return try await body(self)
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { lockWaiters.append($0) }
    }

    private func release() {
        if lockWaiters.isEmpty {
            busy = false
        } else {
            lockWaiters.removeFirst().resume()  // ownership passes directly; `busy` stays true
        }
    }

    // MARK: Raw operations (call only while holding the lock, i.e. inside `exclusive`)

    public func rawWrite(_ command: String) async throws {
        if desynced {
            transport.inbox.discardAll()
            desynced = false
            trace(.note, "resynchronised after timeout")
        }
        trace(.sent, command)
        try await transport.send(Data((command + "\n").utf8))
    }

    public func rawQuery(_ command: String, timeout: Duration? = nil) async throws -> String {
        try await rawWrite(command)
        do {
            let line = try await transport.inbox.line(timeout: timeout ?? defaultTimeout)
            let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            trace(.received, text)
            return text
        } catch {
            throw note(error, command: command)
        }
    }

    public func rawQueryBlock(_ command: String, timeout: Duration? = nil) async throws -> Data {
        try await rawWrite(command)
        let limit = timeout ?? defaultTimeout
        let inbox = transport.inbox
        do {
            let head = try await inbox.bytes(2, timeout: limit)
            guard head[0] == UInt8(ascii: "#"), let digits = Int(String(decoding: head[1...], as: UTF8.self)), digits > 0 else {
                // Not a block: usually the query failed and something else is on the wire.
                let rest = (try? await inbox.line(timeout: .milliseconds(200))) ?? Data()
                desynced = true
                throw SCPIError.malformedResponse(command: command, response: String(decoding: head + rest, as: UTF8.self))
            }
            let lengthField = try await inbox.bytes(digits, timeout: limit)
            guard let length = Int(String(decoding: lengthField, as: UTF8.self)) else {
                desynced = true
                throw SCPIError.malformedResponse(command: command, response: String(decoding: head + lengthField, as: UTF8.self))
            }
            let payload = try await inbox.bytes(length, timeout: limit)
            _ = try await inbox.line(timeout: limit)  // trailing terminator
            trace(.received, "#\(digits)\(length)<\(length) bytes>")
            return payload
        } catch {
            throw note(error, command: command)
        }
    }

    /// Sends a query whose response type is not known in advance (the console) and
    /// returns it as text, or as a block's payload if it starts with `#`.
    public func rawQueryAny(_ command: String, timeout: Duration? = nil) async throws -> SCPIResponse {
        try await rawWrite(command)
        let limit = timeout ?? defaultTimeout
        let inbox = transport.inbox
        do {
            let first = try await inbox.bytes(1, timeout: limit)
            if first[0] == UInt8(ascii: "#") {
                let digitByte = try await inbox.bytes(1, timeout: limit)
                if let digits = Int(String(decoding: digitByte, as: UTF8.self)), digits > 0 {
                    let lengthField = try await inbox.bytes(digits, timeout: limit)
                    if let length = Int(String(decoding: lengthField, as: UTF8.self)) {
                        let payload = try await inbox.bytes(length, timeout: limit)
                        _ = try await inbox.line(timeout: limit)
                        trace(.received, "#\(digits)\(length)<\(length) bytes>")
                        return .block(payload)
                    }
                }
                desynced = true
                throw SCPIError.malformedResponse(command: command, response: "#…")
            }
            let rest = first[0] == 0x0A ? Data() : try await inbox.line(timeout: limit)
            let text = String(decoding: first + rest, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            trace(.received, text)
            return .text(text)
        } catch {
            throw note(error, command: command)
        }
    }

    public func rawDrainErrors() async throws -> [InstrumentError] {
        var errors: [InstrumentError] = []
        // The queue holds at most 20 entries; the bound only guards against a misbehaving peer.
        for _ in 0..<32 {
            let response = try await rawQuery("SYST:ERR?")
            guard let entry = InstrumentError(response: response) else {
                throw SCPIError.malformedResponse(command: "SYST:ERR?", response: response)
            }
            if entry.code == 0 { break }
            errors.append(entry)
        }
        return errors
    }

    public func rawSet(_ command: String) async throws {
        try await rawWrite(command)
        let errors = try await rawDrainErrors()
        if !errors.isEmpty { throw SCPIError.instrument(errors, command: command) }
    }

    // MARK: Helpers

    private func note(_ error: any Error, command: String) -> any Error {
        guard let scpi = error as? SCPIError else { return error }
        if case .timeout = scpi {
            desynced = true
            trace(.note, "timeout waiting for response to \(command)")
            return SCPIError.timeout(command: command)
        }
        return scpi
    }

    private func trace(_ direction: SCPITrafficEvent.Direction, _ text: String) {
        trafficHandler?(SCPITrafficEvent(date: Date(), direction: direction, text: text))
    }
}
