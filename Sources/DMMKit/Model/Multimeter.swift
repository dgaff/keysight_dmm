import Foundation

/// High-level handle to one connected Truevolt multimeter.
///
/// Connecting never resets or reconfigures the meter: the user may have set it up from
/// the front panel, and the app should adopt that state rather than destroy it.
public actor Multimeter {
    public nonisolated let session: SCPISession
    public nonisolated let identity: InstrumentIdentity
    /// Errors that were already in the instrument's queue when we connected.
    public nonisolated let errorsAtConnect: [InstrumentError]

    private var isOpen = true

    private init(session: SCPISession, identity: InstrumentIdentity, errorsAtConnect: [InstrumentError]) {
        self.session = session
        self.identity = identity
        self.errorsAtConnect = errorsAtConnect
    }

    /// Opens the transport and identifies the instrument.
    public static func connect(
        transport: any SCPITransport,
        timeout: Duration = .seconds(5),
        trafficHandler: (@Sendable (SCPITrafficEvent) -> Void)? = nil
    ) async throws -> Multimeter {
        try await transport.connect(timeout: timeout)
        let session = SCPISession(transport: transport)
        await session.setTrafficHandler(trafficHandler)
        do {
            let idn = try await session.query("*IDN?")
            guard let identity = InstrumentIdentity(idn: idn) else {
                throw SCPIError.malformedResponse(command: "*IDN?", response: idn)
            }
            let stale = try await session.drainErrors()
            return Multimeter(session: session, identity: identity, errorsAtConnect: stale)
        } catch {
            await transport.close()
            throw error
        }
    }

    // MARK: Function

    public func function() async throws -> MeasurementFunction {
        let response = try await session.query("FUNC?")
        guard let function = MeasurementFunction(scpiResponse: response) else {
            throw SCPIError.malformedResponse(command: "FUNC?", response: response)
        }
        return function
    }

    public func setFunction(_ function: MeasurementFunction) async throws {
        try await session.set("FUNC \"\(function.scpi)\"")
    }

    // MARK: Measurement

    /// Triggers one measurement with the current configuration and returns it (`READ?`).
    /// Note that `READ?` clears the meter's reading memory first.
    public func read(timeout: Duration = .seconds(15)) async throws -> Reading {
        let response = try await session.query("READ?", timeout: timeout)
        // With a sample/trigger count above one READ? returns a list; take the last.
        guard let last = response.split(separator: ",").last, let reading = Reading(response: String(last)) else {
            throw SCPIError.malformedResponse(command: "READ?", response: response)
        }
        return reading
    }

    /// Like `read`, and also fetches the secondary measurement (`READ?;DATA2?`).
    /// The secondary is nil when none is configured (the meter answers 9.91E37).
    public func readWithSecondary(timeout: Duration = .seconds(15)) async throws -> (primary: Reading, secondary: Reading?) {
        let response = try await session.query("READ?;DATA2?", timeout: timeout)
        let parts = response.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let last = parts[0].split(separator: ",").last, let primary = Reading(response: String(last)) else {
            throw SCPIError.malformedResponse(command: "READ?;DATA2?", response: response)
        }
        // DATA2? can return more than one value (e.g. peak-to-peak gives min, max, ptp); keep the first.
        let secondary = parts[1].split(separator: ",").first.flatMap { Reading(response: String($0)) }
        return (primary, secondary?.status == .invalid ? nil : secondary)
    }

    /// `TRIG:SOUR?` as the short-form mnemonic: IMM, EXT, BUS or INT.
    public func triggerSource() async throws -> String {
        try await session.query("TRIG:SOUR?").uppercased()
    }

    /// Stops any measurement in progress and returns the trigger system to idle.
    public func abort() async throws {
        try await session.write("ABOR")
    }

    // MARK: Shutdown

    /// Returns the front panel to local control (`SYST:LOC`).
    ///
    /// Per the manual, a remote-to-local transition clears readings held in memory by a
    /// data-log or digitize run, so callers must retrieve data first.
    public func goToLocal() async throws {
        try await session.write("SYST:LOC")
    }

    /// Orderly shutdown: optionally hand the front panel back, then close the socket.
    /// Never throws; a dead connection is simply closed.
    public func disconnect(returnToLocal: Bool = true) async {
        guard isOpen else { return }
        isOpen = false
        if returnToLocal {
            try? await session.write("SYST:LOC")
        }
        await session.transport.close()
    }
}
