import Foundation

/// Read-only facts about the instrument, for an "About this meter" panel.
public struct MeterInfo: Sendable, Equatable {
    /// Internal temperature in °C.
    public var internalTemperature: Double?
    /// Time since power-on, in seconds.
    public var uptime: Double?
    /// Power-line frequency the meter detected (50 or 60 Hz).
    public var lineFrequency: Double?
    /// `FRON` or `REAR`: which input terminals the front-panel switch selects.
    public var terminals: String?
    public var macAddress: String?
    /// The meter's real-time clock, read as local time.
    public var clock: Date?
    public var calibrationDate: String?
    public var calibrationCount: Int?
    public var autocalDate: String?
    /// Internal temperature at the last autocalibration, °C.
    public var autocalTemperature: Double?
    public var scpiVersion: String?

    public init() {}
}

extension Multimeter {
    /// Reads what it can; anything the model does not answer is left nil.
    public func info() async throws -> MeterInfo {
        var info = MeterInfo()
        func ask(_ query: String) async throws -> String? {
            try await session.queryIfSupported(query, timeout: .seconds(2))
        }
        info.internalTemperature = try await ask("SYST:TEMP?").flatMap(SCPIValue.parseDouble)
        if let parts = try await ask("SYST:UPT?").flatMap(SCPIValue.parseDoubleList), parts.count == 4 {
            info.uptime = ((parts[0] * 24 + parts[1]) * 60 + parts[2]) * 60 + parts[3]
        }
        info.lineFrequency = try await ask("SYST:LFR?").flatMap(SCPIValue.parseDouble)
        info.terminals = try await ask("ROUT:TERM?")
        info.macAddress = try await ask("SYST:COMM:LAN:MAC?").map(SCPIValue.parseString)
        if let date = try await ask("SYST:DATE?").flatMap(SCPIValue.parseDoubleList), date.count == 3,
           let time = try await ask("SYST:TIME?").flatMap(SCPIValue.parseDoubleList), time.count == 3 {
            var components = DateComponents()
            components.year = Int(date[0]); components.month = Int(date[1]); components.day = Int(date[2])
            components.hour = Int(time[0]); components.minute = Int(time[1])
            components.second = Int(time[2]); components.nanosecond = Int((time[2] - time[2].rounded(.down)) * 1e9)
            info.clock = Calendar(identifier: .gregorian).date(from: components)
        }
        info.calibrationDate = try await ask("CAL:DATE?").flatMap(Self.isoDate)
        info.calibrationCount = try await ask("CAL:COUN?").flatMap(SCPIValue.parseInt)
        info.autocalDate = try await ask("SYST:ACAL:DATE?").flatMap(Self.isoDate)
        info.autocalTemperature = try await ask("SYST:ACAL:TEMP?").flatMap(SCPIValue.parseDouble)
        info.scpiVersion = try await ask("SYST:VERS?")
        return info
    }

    /// `+2025,+3,+7` → `2025-03-07`.
    static func isoDate(_ response: String) -> String? {
        guard let parts = SCPIValue.parseDoubleList(response), parts.count == 3 else { return nil }
        let pad = { (n: Double, width: Int) in
            let text = String(Int(n))
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return "\(pad(parts[0], 4))-\(pad(parts[1], 2))-\(pad(parts[2], 2))"
    }

    /// Sets the meter's real-time clock from the Mac's (local time, like the front panel).
    public func setClock(to date: Date = Date()) async throws {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        try await session.set("SYST:DATE \(c.year ?? 2000),\(c.month ?? 1),\(c.day ?? 1)")
        try await session.set("SYST:TIME \(c.hour ?? 0),\(c.minute ?? 0),\(c.second ?? 0)")
    }

    public func beep() async throws {
        try await session.set("SYST:BEEP")
    }

    /// Shows a message on the meter's display (up to 40 characters), or clears it with nil.
    public func setDisplayText(_ text: String?) async throws {
        if let text {
            try await session.set("DISP:TEXT \(SCPIValue.quoted(String(text.prefix(40))))")
        } else {
            try await session.set("DISP:TEXT:CLE")
        }
    }

    /// Runs the power-on self-test (`*TST?`, a few seconds). Returns the failures; empty means pass.
    public func selfTest() async throws -> [InstrumentError] {
        try await session.exclusive { s in
            let result = try await s.rawQuery("*TST?", timeout: .seconds(60))
            let errors = try await s.rawDrainErrors()
            if SCPIValue.parseInt(result) == 0 { return [] }
            return errors.isEmpty ? [InstrumentError(code: 1, message: "Self-test failed")] : errors
        }
    }

    /// Runs autocalibration (`*CAL?`, 34465A/70A; a few seconds). It compensates for
    /// drift with time and temperature and does not alter the stored calibration
    /// constants or need the calibration security code. Returns the failures; empty means pass.
    public func autocalibrate() async throws -> [InstrumentError] {
        try await session.exclusive { s in
            let result = try await s.rawQuery("*CAL?", timeout: .seconds(120))
            let errors = try await s.rawDrainErrors()
            if SCPIValue.parseInt(result) == 0 { return [] }
            return errors.isEmpty ? [InstrumentError(code: 1, message: "Autocalibration failed")] : errors
        }
    }

    /// Returns the meter to its preset state (`SYST:PRES`): like `*RST` but keeps
    /// stored states and I/O settings.
    public func preset() async throws {
        try await session.set("SYST:PRES")
    }

    /// Saves the current setup to one of the meter's five state slots (0–4).
    public func saveState(slot: Int) async throws {
        try await session.set("*SAV \(slot)")
    }

    /// Recalls a setup from a state slot (0–4). Reconfigures the meter.
    public func recallState(slot: Int) async throws {
        try await session.set("*RCL \(slot)")
    }
}
