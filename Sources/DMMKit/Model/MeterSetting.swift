import Foundation

/// Declarative description of one instrument setting, as the front panel presents it.
///
/// The UI renders settings generically from these descriptors, and `Multimeter` reads
/// and writes them generically, so supporting a new setting means adding a table entry
/// in `FunctionProfile`, not new plumbing.
public struct MeterSetting: Sendable, Identifiable, Hashable {
    public struct Choice: Sendable, Hashable, Identifiable {
        /// Short-form upper-case mnemonic, exactly as the meter returns it (e.g. `"IMM"`, `"CALC:DATA"`).
        public let scpi: String
        public let label: String
        public var id: String { scpi }
        public init(_ scpi: String, _ label: String) {
            self.scpi = scpi
            self.label = label
        }
    }

    public enum Control: Sendable, Hashable {
        /// A number restricted to fixed steps (ranges, NPLC). Listed values are the
        /// superset across the family; `Multimeter` filters them to the connected
        /// meter's `MIN…MAX`, which is how model differences are handled.
        case steps([Double], unit: MeasurementUnit)
        /// A free number between the meter's `MIN` and `MAX`.
        case number(unit: MeasurementUnit)
        /// `{OFF|ON}`; the meter answers `0`/`1`.
        case toggle
        /// One of several mnemonics, sent bare (`TRIG:SOUR EXT`).
        case choice([Choice])
        /// One of several mnemonics sent as a quoted string (`VOLT:SEC "PTP"`).
        case quotedChoice([Choice])
    }

    /// Companion `…:AUTO` behaviour for a numeric setting.
    public struct Auto: Sendable, Hashable {
        /// Header of the auto switch, e.g. `VOLT:RANG:AUTO`.
        public let header: String
        /// Whether `ONCE` is accepted (autorange once, auto zero once).
        public let supportsOnce: Bool
        /// Label for the "auto" state in the UI.
        public let label: String
        public init(header: String, supportsOnce: Bool = false, label: String = "Auto") {
            self.header = header
            self.supportsOnce = supportsOnce
            self.label = label
        }
    }

    /// Shows this setting only while another setting has a given value.
    public struct Condition: Sendable, Hashable {
        public let settingID: String
        public let equals: SettingValue
        /// Further conditions that must hold as well.
        public let and: [Condition]
        public init(_ settingID: String, equals: SettingValue, and: [Condition] = []) {
            self.settingID = settingID
            self.equals = equals
            self.and = and
        }

        public func holds(in states: [String: SettingState]) -> Bool {
            states[settingID]?.value == equals && and.allSatisfy { $0.holds(in: states) }
        }
    }

    /// Whether the setting should be shown, given what the meter reported: it must have
    /// answered, and its `visibleWhen` condition (if any) must hold.
    public func isVisible(in states: [String: SettingState]) -> Bool {
        states[id] != nil && (visibleWhen?.holds(in: states) ?? true)
    }

    /// Stable identifier, unique within one function's profile (e.g. `"range"`).
    public let id: String
    /// Front-panel soft-key legend (e.g. "Range", "Auto Zero", "Input Z").
    public let label: String
    /// Section heading used to group related settings in the UI.
    public let group: String
    /// Short-form SCPI header without `?` (e.g. `VOLT:RANG`).
    public let header: String
    public let control: Control
    public let auto: Auto?
    /// One or two sentences explaining what the setting does and when to change it.
    public let help: String
    public let visibleWhen: Condition?
    /// Models that have this setting; nil means the whole family.
    public let models: Set<TruevoltModel>?
    /// Labels for a `.toggle`'s two states where On/Off would be unclear
    /// (Input Z: "10 MΩ" / "Auto (Hi-Z)").
    public let offLabel: String
    public let onLabel: String

    public init(
        id: String, label: String, group: String, header: String, control: Control,
        auto: Auto? = nil, help: String, visibleWhen: Condition? = nil, models: Set<TruevoltModel>? = nil,
        offLabel: String = "Off", onLabel: String = "On"
    ) {
        self.offLabel = offLabel
        self.onLabel = onLabel
        self.id = id
        self.label = label
        self.group = group
        self.header = header
        self.control = control
        self.auto = auto
        self.help = help
        self.visibleWhen = visibleWhen
        self.models = models
    }

    public var unit: MeasurementUnit? {
        switch control {
        case .steps(_, let unit), .number(let unit): unit
        default: nil
        }
    }

    public var isNumeric: Bool { unit != nil }

    /// The command that sets `value`, e.g. `VOLT:RANG 0.1`. Nil if the value's type
    /// does not fit the control.
    public func command(for value: SettingValue) -> String? {
        switch (control, value) {
        case (.steps, .number(let v)), (.number, .number(let v)):
            v.isFinite ? "\(header) \(SCPIValue.number(v))" : nil
        case (.toggle, .bool(let on)):
            "\(header) \(SCPIValue.bool(on))"
        case (.choice(let choices), .choice(let c)):
            choices.contains { $0.scpi == c } ? "\(header) \(c)" : nil
        case (.quotedChoice(let choices), .choice(let c)):
            choices.contains { $0.scpi == c } ? "\(header) \(SCPIValue.quoted(c))" : nil
        default:
            nil
        }
    }

    /// Decodes the meter's answer to `header?`.
    public func parse(response: String) -> SettingValue? {
        switch control {
        case .steps, .number:
            return SCPIValue.parseDouble(response).map(SettingValue.number)
        case .toggle:
            return SCPIValue.parseBool(response).map(SettingValue.bool)
        case .choice(let choices), .quotedChoice(let choices):
            let text = SCPIValue.parseString(response).uppercased()
            if let exact = choices.first(where: { $0.scpi == text }) { return .choice(exact.scpi) }
            // Tolerate long-form answers ("CALCULATE:DATA" for "CALC:DATA").
            let match = choices.first { MeterSetting.shortForm(of: text) == $0.scpi }
            return match.map { .choice($0.scpi) }
        }
    }

    /// Reduces a long-form mnemonic path to SCPI short form: each node keeps its first
    /// four letters, or three if the fourth is a vowel (`VOLTAGE` → `VOLT`, `PERIOD` → `PER`).
    static func shortForm(of path: String) -> String {
        path.split(separator: ":", omittingEmptySubsequences: false).map { node -> String in
            let letters = node.prefix { $0.isLetter }
            let rest = node.dropFirst(letters.count)
            guard letters.count > 4 else { return String(node) }
            let fourth = letters[letters.index(letters.startIndex, offsetBy: 3)]
            return String(letters.prefix("AEIOU".contains(fourth) ? 3 : 4)) + rest
        }.joined(separator: ":")
    }
}

public enum SettingValue: Sendable, Hashable {
    case number(Double)
    case bool(Bool)
    case choice(String)

    public var number: Double? { if case .number(let v) = self { v } else { nil } }
    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var choice: String? { if case .choice(let v) = self { v } else { nil } }
}

/// What the meter reported for one setting.
public struct SettingState: Sendable, Hashable {
    public var value: SettingValue
    /// State of the companion `:AUTO` switch, if the setting has one.
    public var auto: Bool?
    /// Limits from `header? MIN` / `header? MAX` (numeric settings only).
    public var minimum: Double?
    public var maximum: Double?
    /// For `.steps` controls: the listed steps that fall within the meter's limits.
    public var allowedSteps: [Double]?

    public init(value: SettingValue, auto: Bool? = nil, minimum: Double? = nil, maximum: Double? = nil, allowedSteps: [Double]? = nil) {
        self.value = value
        self.auto = auto
        self.minimum = minimum
        self.maximum = maximum
        self.allowedSteps = allowedSteps
    }
}

public enum AutoMode: String, Sendable {
    case off = "OFF", on = "ON", once = "ONCE"
}

/// A function's settings in display order.
public struct FunctionProfile: Sendable {
    public let function: MeasurementFunction
    public let settings: [MeterSetting]

    public init(function: MeasurementFunction, settings: [MeterSetting]) {
        self.function = function
        self.settings = settings
    }

    /// Settings available on `model`, in order.
    public func settings(for model: TruevoltModel?) -> [MeterSetting] {
        guard let model else { return settings }
        return settings.filter { $0.models?.contains(model) ?? true }
    }

    /// Group names in first-appearance order.
    public var groups: [String] {
        var seen = Set<String>()
        return settings.map(\.group).filter { seen.insert($0).inserted }
    }

    public func setting(_ id: String) -> MeterSetting? { settings.first { $0.id == id } }
}
