import Foundation

/// The meter's primary measurement functions.
public enum MeasurementFunction: String, Sendable, CaseIterable, Identifiable, Codable {
    case dcVoltage, acVoltage, dcCurrent, acCurrent
    case resistance2W, resistance4W
    case frequency, period
    case capacitance, temperature
    case continuity, diode
    case dcRatio

    public var id: String { rawValue }

    /// Short-form header used with `FUNC`, `CONF:` and `SENS:` commands. This is also
    /// exactly what `FUNC?` returns (inside quotes).
    public var scpi: String {
        switch self {
        case .dcVoltage: "VOLT"
        case .acVoltage: "VOLT:AC"
        case .dcCurrent: "CURR"
        case .acCurrent: "CURR:AC"
        case .resistance2W: "RES"
        case .resistance4W: "FRES"
        case .frequency: "FREQ"
        case .period: "PER"
        case .capacitance: "CAP"
        case .temperature: "TEMP"
        case .continuity: "CONT"
        case .diode: "DIOD"
        case .dcRatio: "VOLT:RAT"
        }
    }

    /// Parses a `FUNC?` response such as `"VOLT:AC"`. Tolerates long forms and an explicit `:DC`.
    public init?(scpiResponse: String) {
        var s = SCPIValue.parseString(scpiResponse).uppercased()
        if s.hasSuffix(":DC") { s.removeLast(3) }
        let aliases: [String: MeasurementFunction] = [
            "VOLT": .dcVoltage, "VOLTAGE": .dcVoltage,
            "VOLT:AC": .acVoltage, "VOLTAGE:AC": .acVoltage,
            "CURR": .dcCurrent, "CURRENT": .dcCurrent,
            "CURR:AC": .acCurrent, "CURRENT:AC": .acCurrent,
            "RES": .resistance2W, "RESISTANCE": .resistance2W,
            "FRES": .resistance4W, "FRESISTANCE": .resistance4W,
            "FREQ": .frequency, "FREQUENCY": .frequency,
            "PER": .period, "PERIOD": .period,
            "CAP": .capacitance, "CAPACITANCE": .capacitance,
            "TEMP": .temperature, "TEMPERATURE": .temperature,
            "CONT": .continuity, "CONTINUITY": .continuity,
            "DIOD": .diode, "DIODE": .diode,
            "VOLT:RAT": .dcRatio, "VOLTAGE:RATIO": .dcRatio, "VOLT:DC:RAT": .dcRatio,
        ]
        guard let match = aliases[s] else { return nil }
        self = match
    }

    /// Name as printed on the front panel / shown on the meter's display.
    public var displayName: String {
        switch self {
        case .dcVoltage: "DC Voltage"
        case .acVoltage: "AC Voltage"
        case .dcCurrent: "DC Current"
        case .acCurrent: "AC Current"
        case .resistance2W: "2-Wire Resistance"
        case .resistance4W: "4-Wire Resistance"
        case .frequency: "Frequency"
        case .period: "Period"
        case .capacitance: "Capacitance"
        case .temperature: "Temperature"
        case .continuity: "Continuity"
        case .diode: "Diode"
        case .dcRatio: "DCV Ratio"
        }
    }

    /// Front-panel key legend, for "where is this on the meter" hints.
    public var frontPanelKey: String {
        switch self {
        case .dcVoltage: "DCV"
        case .acVoltage: "ACV"
        case .dcCurrent: "DCI"
        case .acCurrent: "ACI"
        case .resistance2W: "Ω2W"
        case .resistance4W: "Ω4W"
        case .frequency: "Freq"
        case .period: "Freq › Period"
        case .capacitance: "Cap (Shift+Freq)"
        case .temperature: "Temp"
        case .continuity: "Cont"
        case .diode: "Diode (Shift+Cont)"
        case .dcRatio: "DCV › DCV Ratio"
        }
    }

    /// Unit of the raw reading. Temperature depends on `UNIT:TEMP`; this is the default.
    public var unit: MeasurementUnit {
        switch self {
        case .dcVoltage, .acVoltage, .diode: .volt
        case .dcCurrent, .acCurrent: .ampere
        case .resistance2W, .resistance4W, .continuity: .ohm
        case .frequency: .hertz
        case .period: .second
        case .capacitance: .farad
        case .temperature: .celsius
        case .dcRatio: .none
        }
    }

    /// Suffix the meter shows after the unit ("VDC", "VAC").
    public var unitQualifier: String {
        switch self {
        case .dcVoltage, .dcCurrent: "DC"
        case .acVoltage, .acCurrent: "AC"
        default: ""
        }
    }
}
