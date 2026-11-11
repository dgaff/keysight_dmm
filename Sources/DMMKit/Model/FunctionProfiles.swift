import Foundation

/// Per-function setting tables. Labels follow the front-panel soft keys so the app
/// teaches the same vocabulary as the instrument.
///
/// Step lists are the superset across the Truevolt family; the connected meter's
/// `MIN`/`MAX` answers trim them (see `Multimeter.readSettings`).
extension FunctionProfile {
    /// The function's own settings followed by the math settings (scaling, limits)
    /// that apply to it.
    public static func profile(for function: MeasurementFunction) -> FunctionProfile {
        let own = measurementSettings(for: function)
        return FunctionProfile(function: function, settings: own.settings + mathSettings(for: function))
    }

    static func measurementSettings(for function: MeasurementFunction) -> FunctionProfile {
        switch function {
        case .dcVoltage: dcVoltage
        case .acVoltage: acVoltage
        case .dcCurrent: dcCurrent
        case .acCurrent: acCurrent
        case .resistance2W: resistance2W
        case .resistance4W: resistance4W
        case .frequency: frequency
        case .period: period
        case .capacitance: capacitance
        case .temperature: temperature
        case .continuity: continuity
        case .diode: diode
        case .dcRatio: dcRatio
        }
    }

    // MARK: Math (manual pp. 101–113, 206–232). Verified on a 34470A: with scaling on,
    // READ? returns the scaled value; continuity and diode reject scaling (-221).

    static func mathSettings(for function: MeasurementFunction) -> [MeterSetting] {
        switch function {
        case .continuity, .diode, .dcRatio: return []
        default: break
        }
        let isVoltage = function == .dcVoltage || function == .acVoltage
        let on = MeterSetting.Condition("scaling", equals: .bool(true))
        func when(_ kind: String) -> MeterSetting.Condition {
            .init("scalingFunction", equals: .choice(kind), and: [on])
        }
        // The selection is shared by all functions on the meter, so dB and dBm are listed
        // everywhere (the meter may report them); it refuses them outside voltage.
        let note = isVoltage ? "" : " (voltage only)"
        let kinds: [MeterSetting.Choice] = [
            .init("DB", "dB" + note), .init("DBM", "dBm" + note),
            .init("PCT", "Percent change"), .init("SCAL", "Gain and offset (Mx-B)"),
        ]
        let limitsOn = MeterSetting.Condition("limits", equals: .bool(true))

        var settings: [MeterSetting] = [
            MeterSetting(
                id: "scaling", label: "Scaling", group: "Scaling", header: "CALC:SCAL:STAT",
                control: .toggle,
                help: "Converts every reading with the chosen function before it is displayed and returned. The meter turns scaling off whenever the measurement function changes."),
            MeterSetting(
                id: "scalingFunction", label: "Function", group: "Scaling", header: "CALC:SCAL:FUNC",
                control: .choice(kinds),
                help: "What scaling computes: dB or dBm (voltage only), percent change from a reference, or reading × gain − offset.",
                visibleWhen: on),
        ]
        if isVoltage {
            settings += [
                MeterSetting(
                    id: "dbmReference", label: "Ref R", group: "Scaling", header: "CALC:SCAL:DBM:REF",
                    control: .steps([50, 75, 93, 110, 124, 125, 135, 150, 250, 300, 500, 600, 800, 900, 1000, 1200, 8000], unit: .ohm),
                    help: "The load resistance the power is referred to: dBm = 10·log10(V² / R / 1 mW). Use the impedance of the system being measured (600 Ω audio, 50 Ω RF).",
                    visibleWhen: when("DBM")),
                MeterSetting(
                    id: "dbReference", label: "dB Ref Value", group: "Scaling", header: "CALC:SCAL:DB:REF",
                    control: .number(unit: .dBm),
                    auto: .init(header: "CALC:SCAL:REF:AUTO", label: "Use first reading"),
                    help: "The level, in dBm, that reads as 0 dB. Readings show how far above or below it they are. The dBm conversion uses the reference resistance set for dBm.",
                    visibleWhen: when("DB")),
            ]
        }
        settings += [
            MeterSetting(
                id: "percentReference", label: "Reference", group: "Scaling", header: "CALC:SCAL:REF",
                control: .number(unit: function.unit),
                auto: .init(header: "CALC:SCAL:REF:AUTO", label: "Use first reading"),
                help: "The value that reads as 0 %. Readings show the percentage difference from it.",
                visibleWhen: when("PCT"), models: advancedModels),
            MeterSetting(
                id: "gain", label: "Gain (M)", group: "Scaling", header: "CALC:SCAL:GAIN",
                control: .number(unit: .none),
                help: "Each reading is multiplied by this before the offset is subtracted. Use it to convert a sensor's output to its real quantity.",
                visibleWhen: when("SCAL"), models: advancedModels),
            MeterSetting(
                id: "offset", label: "Offset (B)", group: "Scaling", header: "CALC:SCAL:OFFS",
                control: .number(unit: .none),
                help: "Subtracted from each reading after the gain is applied.",
                visibleWhen: when("SCAL"), models: advancedModels),
            MeterSetting(
                id: "limits", label: "Limits", group: "Limits", header: "CALC:LIM:STAT",
                control: .toggle,
                help: "Has the meter itself check each reading against a lower and upper limit. The meter's display shows pass or fail, and a rear-panel pulse can be issued. This is separate from the limit lines the app draws on a data log."),
            MeterSetting(
                id: "limitLower", label: "Low", group: "Limits", header: "CALC:LIM:LOW",
                control: .number(unit: function.unit),
                help: "Readings below this fail. Compared with the reading as displayed, so after null and scaling.",
                visibleWhen: limitsOn),
            MeterSetting(
                id: "limitUpper", label: "High", group: "Limits", header: "CALC:LIM:UPP",
                control: .number(unit: function.unit),
                help: "Readings above this fail. Compared with the reading as displayed, so after null and scaling.",
                visibleWhen: limitsOn),
        ]
        return settings
    }

    // MARK: Shared building blocks

    static let allModels: Set<TruevoltModel> = Set(TruevoltModel.allCases)
    static let advancedModels: Set<TruevoltModel> = [.m34465A, .m34470A]

    /// NPLC steps across the family (0.001–0.006 need a 34465A/70A).
    static let nplcSteps: [Double] = [0.001, 0.002, 0.006, 0.02, 0.06, 0.2, 1, 10, 100]

    static func nullSettings(prefix: String, unit: MeasurementUnit) -> [MeterSetting] {
        [
            MeterSetting(
                id: "null", label: "Null", group: "Null", header: "\(prefix):NULL",
                control: .toggle,
                help: "Subtracts the null value from every reading. Use it to remove test-lead resistance or a fixed offset."),
            MeterSetting(
                id: "nullValue", label: "Null Value", group: "Null", header: "\(prefix):NULL:VAL",
                control: .number(unit: unit),
                auto: .init(header: "\(prefix):NULL:VAL:AUTO", label: "Use first reading"),
                help: "The value subtracted while Null is on. With automatic selection the meter uses the first reading taken after Null is enabled.",
                visibleWhen: .init("null", equals: .bool(true))),
        ]
    }

    // MARK: DC voltage (manual pp. 57–59, 365–382)

    static let dcVoltage = FunctionProfile(function: .dcVoltage, settings: [
        MeterSetting(
            id: "range", label: "Range", group: "Range", header: "VOLT:RANG",
            control: .steps([0.1, 1, 10, 100, 1000], unit: .volt),
            auto: .init(header: "VOLT:RANG:AUTO", supportsOnce: true),
            help: "Full-scale range. Autorange picks the range for each reading; a fixed range is faster and avoids range-change glitches."),
        MeterSetting(
            id: "apertureMode", label: "Aperture", group: "Integration", header: "VOLT:APER:ENAB",
            control: .toggle,
            help: "Chooses how integration time is specified: in power-line cycles (NPLC), which rejects mains noise at 1 PLC and above, or directly as a time in seconds.",
            models: advancedModels, offLabel: "NPLC", onLabel: "Time"),
        MeterSetting(
            id: "nplc", label: "NPLC", group: "Integration", header: "VOLT:NPLC",
            control: .steps(nplcSteps, unit: .none),
            help: "Integration time in power-line cycles. More cycles give lower noise and more resolution but slower readings; only whole cycles (1, 10, 100) reject line-frequency noise."),
        MeterSetting(
            id: "aperture", label: "Aperture Time", group: "Integration", header: "VOLT:APER",
            control: .number(unit: .second),
            help: "Integration time in seconds, used instead of NPLC when Aperture is set to Time.",
            visibleWhen: .init("apertureMode", equals: .bool(true)), models: advancedModels),
        MeterSetting(
            id: "autoZero", label: "Auto Zero", group: "Accuracy", header: "VOLT:ZERO:AUTO",
            control: .toggle,
            help: "When on, the meter measures its internal offset after every reading and subtracts it: most accurate, half the speed. Off uses the last zero measurement."),
        MeterSetting(
            id: "inputZ", label: "Input Z", group: "Accuracy", header: "VOLT:IMP:AUTO",
            control: .toggle,
            help: "Input impedance. 10 MΩ on every range, or Auto: more than 10 GΩ on the 100 mV, 1 V and 10 V ranges to avoid loading high-impedance sources.",
            offLabel: "10 MΩ", onLabel: "Auto (Hi-Z)"),
    ] + nullSettings(prefix: "VOLT", unit: .volt) + [
        MeterSetting(
            id: "secondary", label: "2nd Meas", group: "Secondary", header: "VOLT:SEC",
            control: .quotedChoice([
                .init("OFF", "Off"), .init("CALC:DATA", "Pre-math value"),
                .init("VOLT:AC", "AC voltage"), .init("PTP", "Peak-to-peak"),
            ]),
            help: "A second value shown alongside the main reading.", models: advancedModels),
    ])

    // MARK: More shared building blocks

    static let preMath = MeterSetting.Choice("CALC:DATA", "Pre-math value")
    static let secondaryOff = MeterSetting.Choice("OFF", "Off")

    /// AC filter: the lowest signal frequency the AC converter must handle.
    static let acFilterSteps: [Double] = [3, 20, 200]

    /// Aperture mode, NPLC and aperture time for functions that have all three
    /// (`prefix:APER:ENAB`, `prefix:NPLC`, `prefix:APER`).
    static func integrationSettings(prefix: String) -> [MeterSetting] {
        [
            MeterSetting(
                id: "apertureMode", label: "Aperture", group: "Integration", header: "\(prefix):APER:ENAB",
                control: .toggle,
                help: "Chooses how integration time is specified: in power-line cycles (NPLC), which rejects mains noise at 1 PLC and above, or directly as a time in seconds.",
                models: advancedModels, offLabel: "NPLC", onLabel: "Time"),
            MeterSetting(
                id: "nplc", label: "NPLC", group: "Integration", header: "\(prefix):NPLC",
                control: .steps(nplcSteps, unit: .none),
                help: "Integration time in power-line cycles. More cycles give lower noise and more resolution but slower readings; only whole cycles (1, 10, 100) reject line-frequency noise."),
            MeterSetting(
                id: "aperture", label: "Aperture Time", group: "Integration", header: "\(prefix):APER",
                control: .number(unit: .second),
                help: "Integration time in seconds, used instead of NPLC when Aperture is set to Time.",
                visibleWhen: .init("apertureMode", equals: .bool(true)), models: advancedModels),
        ]
    }

    static func autoZeroSetting(prefix: String) -> MeterSetting {
        MeterSetting(
            id: "autoZero", label: "Auto Zero", group: "Accuracy", header: "\(prefix):ZERO:AUTO",
            control: .toggle,
            help: "When on, the meter measures its internal offset after every reading and subtracts it: most accurate, half the speed. Off reuses the last zero measurement.")
    }

    static func rangeSetting(
        header: String, steps: [Double], unit: MeasurementUnit, help: String
    ) -> MeterSetting {
        MeterSetting(
            id: "range", label: "Range", group: "Range", header: header,
            control: .steps(steps, unit: unit),
            auto: .init(header: "\(header):AUTO", supportsOnce: true),
            help: help)
    }

    static func acFilterSetting(header: String, help: String) -> MeterSetting {
        MeterSetting(
            id: "acFilter", label: "AC Filter", group: "Filter", header: header,
            control: .steps(acFilterSteps, unit: .hertz), help: help)
    }

    static func secondarySetting(header: String, choices: [MeterSetting.Choice]) -> MeterSetting {
        MeterSetting(
            id: "secondary", label: "2nd Meas", group: "Secondary", header: header,
            control: .quotedChoice(choices),
            help: "A second value shown alongside the main reading. Read it over SCPI with DATA2? after a measurement.",
            models: advancedModels)
    }

    static let currentRangeHelp = "Full-scale range on the 3 A terminals. Autorange picks the range for each reading; a fixed range is faster and avoids range-change glitches. The 10 A terminal always uses its own range."

    static func terminalsSetting(header: String) -> MeterSetting {
        MeterSetting(
            id: "terminals", label: "Terminals", group: "Terminals", header: header,
            control: .steps([3, 10], unit: .ampere),
            help: "Which current input to measure on, the 3 A or the 10 A terminal. Choosing 10 A switches to the 10 A range; the lead must be moved to match.",
            models: [.m34461A, .m34465A, .m34470A])
    }

    static let switchModeSetting = MeterSetting(
        id: "switchMode", label: "Range Switch", group: "Range", header: "CURR:SWIT:MODE",
        control: .choice([.init("CONT", "Continuous"), .init("FAST", "Fast")]),
        help: "How the meter changes current ranges. Continuous never opens the circuit while switching shunts but is slower; Fast can open the circuit for a moment.",
        models: advancedModels)

    static let resistanceRanges: [Double] = [100, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9]

    /// Range and integration settings common to 2-wire and 4-wire resistance; `prefix` is `RES` or `FRES`.
    static func resistanceSettings(prefix: String) -> [MeterSetting] {
        [
            rangeSetting(
                header: "\(prefix):RANG", steps: resistanceRanges, unit: .ohm,
                help: "Full-scale range. Autorange picks the range for each reading; a fixed range is faster. The 1 GΩ range exists on the 34465A/70A only."),
        ] + integrationSettings(prefix: prefix)
    }

    static func resistanceAccuracy(prefix: String) -> [MeterSetting] {
        [
            MeterSetting(
                id: "offsetComp", label: "OffstComp", group: "Accuracy", header: "\(prefix):OCOM",
                control: .toggle,
                help: "Offset compensation takes two readings at different test currents and uses the difference, cancelling small DC voltages in the circuit. It roughly doubles the reading time.",
                models: advancedModels),
            MeterSetting(
                id: "lowPower", label: "Low Power", group: "Accuracy", header: "\(prefix):POW:LIM",
                control: .toggle,
                help: "Uses a lower test current on the 100 Ω to 100 kΩ ranges, which reduces heating in delicate or temperature-sensitive parts. Higher ranges are unaffected.",
                models: advancedModels),
        ]
    }

    // MARK: AC voltage (manual pp. 60–62, 370–376)

    static let acVoltage = FunctionProfile(function: .acVoltage, settings: [
        rangeSetting(
            header: "VOLT:AC:RANG", steps: [0.1, 1, 10, 100, 1000], unit: .volt,
            help: "Full-scale range. Autorange picks the range for each reading; a fixed range is faster and avoids range-change glitches."),
        acFilterSetting(
            header: "VOLT:AC:BAND",
            help: "Set this to the lowest frequency you expect to measure. Lower settings measure low frequencies accurately but wait longer for each reading to settle."),
    ] + nullSettings(prefix: "VOLT:AC", unit: .volt) + [
        secondarySetting(header: "VOLT:AC:SEC", choices: [
            secondaryOff, preMath, .init("FREQ", "Frequency"), .init("VOLT", "DC voltage"),
        ]),
    ])

    // MARK: DC current (manual pp. 63–64, 315–329)

    static let dcCurrent = FunctionProfile(function: .dcCurrent, settings: [
        terminalsSetting(header: "CURR:TERM"),
        rangeSetting(
            header: "CURR:RANG", steps: [1e-6, 1e-5, 1e-4, 1e-3, 1e-2, 0.1, 1, 3, 10], unit: .ampere,
            help: currentRangeHelp),
        switchModeSetting,
    ] + integrationSettings(prefix: "CURR") + [
        autoZeroSetting(prefix: "CURR"),
    ] + nullSettings(prefix: "CURR", unit: .ampere) + [
        secondarySetting(header: "CURR:SEC", choices: [
            secondaryOff, preMath, .init("CURR:AC", "AC current"), .init("PTP", "Peak-to-peak"),
        ]),
    ])

    // MARK: AC current (manual pp. 65–66, 315–329)

    static let acCurrent = FunctionProfile(function: .acCurrent, settings: [
        terminalsSetting(header: "CURR:AC:TERM"),
        rangeSetting(
            header: "CURR:AC:RANG", steps: [1e-4, 1e-3, 1e-2, 0.1, 1, 3, 10], unit: .ampere,
            help: currentRangeHelp),
        switchModeSetting,
        acFilterSetting(
            header: "CURR:AC:BAND",
            help: "Set this to the lowest frequency you expect to measure. Lower settings measure low frequencies accurately but wait longer for each reading to settle."),
    ] + nullSettings(prefix: "CURR:AC", unit: .ampere) + [
        secondarySetting(header: "CURR:AC:SEC", choices: [
            secondaryOff, preMath, .init("FREQ", "Frequency"), .init("CURR", "DC current"),
        ]),
    ])

    // MARK: Resistance (manual pp. 66–68, 340–353)

    static let resistance2W = FunctionProfile(function: .resistance2W, settings:
        resistanceSettings(prefix: "RES") + [autoZeroSetting(prefix: "RES")]
        + resistanceAccuracy(prefix: "RES") + nullSettings(prefix: "RES", unit: .ohm) + [
        secondarySetting(header: "RES:SEC", choices: [secondaryOff, preMath]),
    ])

    /// 4-wire resistance has no auto-zero setting: it is always on.
    static let resistance4W = FunctionProfile(function: .resistance4W, settings:
        resistanceSettings(prefix: "FRES")
        + resistanceAccuracy(prefix: "FRES") + nullSettings(prefix: "FRES", unit: .ohm) + [
        secondarySetting(header: "FRES:SEC", choices: [secondaryOff, preMath]),
    ])

    // MARK: Frequency and period (manual pp. 79–80, 332–339)

    /// Frequency and period share range, filter, gate time and timeout on the meter, but
    /// each has its own null and secondary. `prefix` is `FREQ` or `PER`.
    static func frequencyLikeSettings(prefix: String, nullUnit: MeasurementUnit, secondary: [MeterSetting.Choice]) -> [MeterSetting] {
        [
            rangeSetting(
                header: "\(prefix):VOLT:RANG", steps: [0.1, 1, 10, 100, 1000], unit: .volt,
                help: "Voltage range of the input amplifier. Autorange follows the signal level; a fixed range avoids range changes on a steady signal."),
            acFilterSetting(
                header: "\(prefix):RANG:LOW",
                help: "Set this to the lowest frequency you expect to measure. Lower settings detect slow signals but wait longer for each reading."),
            MeterSetting(
                id: "gateTime", label: "Gate Time", group: "Integration", header: "\(prefix):APER",
                control: .steps([0.001, 0.01, 0.1, 1], unit: .second),
                help: "How long the meter counts signal edges for each reading. Longer gates give more digits but slower readings. The 1 ms gate needs a 34465A/70A."),
            MeterSetting(
                id: "timeout", label: "Timeout", group: "Filter", header: "FREQ:TIM:AUTO",
                control: .toggle,
                help: "How long the meter waits for a signal before returning 0. Fixed is 1 s; Auto shortens the wait when the AC filter is fast, which speeds up testing of dead inputs.",
                models: advancedModels, offLabel: "1 s", onLabel: "Auto"),
        ] + nullSettings(prefix: prefix, unit: nullUnit) + [
            secondarySetting(header: "\(prefix):SEC", choices: secondary),
        ]
    }

    static let frequency = FunctionProfile(function: .frequency, settings: frequencyLikeSettings(
        prefix: "FREQ", nullUnit: .hertz,
        secondary: [secondaryOff, preMath, .init("PER", "Period"), .init("VOLT:AC", "AC voltage")]))

    static let period = FunctionProfile(function: .period, settings: frequencyLikeSettings(
        prefix: "PER", nullUnit: .second,
        secondary: [secondaryOff, preMath, .init("FREQ", "Frequency"), .init("VOLT:AC", "AC voltage")]))

    // MARK: Capacitance (manual pp. 77–78, 309–314)

    static let capacitance = FunctionProfile(function: .capacitance, settings: [
        rangeSetting(
            header: "CAP:RANG", steps: [1e-9, 1e-8, 1e-7, 1e-6, 1e-5, 1e-4], unit: .farad,
            help: "Full-scale range. Autorange picks the range for each reading; a fixed range is faster once you know the part's size."),
    ] + nullSettings(prefix: "CAP", unit: .farad) + [
        secondarySetting(header: "CAP:SEC", choices: [secondaryOff, preMath]),
    ])

    // MARK: Temperature (manual pp. 69–76, 354–368)

    static let rtdR0Help = "The RTD's nominal resistance at 0 \u{00B0}C (100 \u{03A9} for a Pt100). Set it to match your sensor's datasheet."
    static let rtdOffsetHelp = "Offset compensation cancels small DC voltages in the RTD circuit by measuring at two test currents. It roughly doubles the reading time."
    static let rtdLowPowerHelp = "Uses a lower test current through the RTD to reduce self-heating, at the cost of a little more noise."
    static let thermistorLowPowerHelp = "Uses a lower test current through the thermistor to reduce self-heating."

    static func probeIs(_ mnemonic: String) -> MeterSetting.Condition {
        .init("probe", equals: .choice(mnemonic))
    }

    static let temperature = FunctionProfile(function: .temperature, settings: [
        MeterSetting(
            id: "probe", label: "Probe", group: "Probe", header: "TEMP:TRAN:TYPE",
            control: .choice([
                .init("FRTD", "RTD 4w"), .init("RTD", "RTD 2w"),
                .init("FTH", "Thermis4w"), .init("THER", "Thermis2w"),
                .init("TC", "TCouple"),
            ]),
            help: "The kind of sensor connected. Four-wire probes cancel lead resistance. Thermocouples need a 34465A/70A."),
        MeterSetting(
            id: "frtdR0", label: "R0", group: "Probe", header: "TEMP:TRAN:FRTD:RES",
            control: .number(unit: .ohm), help: rtdR0Help, visibleWhen: probeIs("FRTD")),
        MeterSetting(
            id: "rtdR0", label: "R0", group: "Probe", header: "TEMP:TRAN:RTD:RES",
            control: .number(unit: .ohm), help: rtdR0Help, visibleWhen: probeIs("RTD")),
        MeterSetting(
            id: "frtdOffsetComp", label: "OffstComp", group: "Accuracy", header: "TEMP:TRAN:FRTD:OCOM",
            control: .toggle, help: rtdOffsetHelp, visibleWhen: probeIs("FRTD"), models: advancedModels),
        MeterSetting(
            id: "rtdOffsetComp", label: "OffstComp", group: "Accuracy", header: "TEMP:TRAN:RTD:OCOM",
            control: .toggle, help: rtdOffsetHelp, visibleWhen: probeIs("RTD"), models: advancedModels),
        MeterSetting(
            id: "frtdLowPower", label: "Low Power", group: "Accuracy", header: "TEMP:TRAN:FRTD:POW:LIM",
            control: .toggle, help: rtdLowPowerHelp, visibleWhen: probeIs("FRTD"), models: advancedModels),
        MeterSetting(
            id: "rtdLowPower", label: "Low Power", group: "Accuracy", header: "TEMP:TRAN:RTD:POW:LIM",
            control: .toggle, help: rtdLowPowerHelp, visibleWhen: probeIs("RTD"), models: advancedModels),
        MeterSetting(
            id: "fthermLowPower", label: "Low Power", group: "Accuracy", header: "TEMP:TRAN:FTH:POW:LIM",
            control: .toggle, help: thermistorLowPowerHelp, visibleWhen: probeIs("FTH"), models: advancedModels),
        MeterSetting(
            id: "thermLowPower", label: "Low Power", group: "Accuracy", header: "TEMP:TRAN:THER:POW:LIM",
            control: .toggle, help: thermistorLowPowerHelp, visibleWhen: probeIs("THER"), models: advancedModels),
        MeterSetting(
            id: "tcType", label: "Type", group: "Probe", header: "TEMP:TRAN:TC:TYPE",
            control: .choice(["E", "J", "K", "N", "R", "T"].map { MeterSetting.Choice($0, "Type \($0)") }),
            help: "The thermocouple type; it selects the conversion table. It must match the wire you are using.",
            visibleWhen: probeIs("TC"), models: advancedModels),
        MeterSetting(
            id: "tcRefType", label: "Reference", group: "Probe", header: "TEMP:TRAN:TC:RJUN:TYPE",
            control: .choice([.init("INT", "Internal"), .init("FIX", "Fixed")]),
            help: "Where the cold-junction temperature comes from: the meter's own front terminals, or a fixed value you enter for an external reference junction.",
            visibleWhen: probeIs("TC"), models: advancedModels),
        MeterSetting(
            id: "tcRefTemp", label: "Fixed Offset", group: "Probe", header: "TEMP:TRAN:TC:RJUN",
            control: .number(unit: .celsius),
            help: "The known temperature of an external reference junction. Always entered in \u{00B0}C, whatever the display unit.",
            visibleWhen: .init("tcRefType", equals: .choice("FIX")), models: advancedModels),
        MeterSetting(
            id: "tcRefAdjust", label: "Offset Adjust", group: "Probe", header: "TEMP:TRAN:TC:RJUN:OFFS:ADJ",
            control: .number(unit: .celsius),
            help: "A correction added to the meter's internal reference-junction reading. Leave at 0 unless a calibration shows the terminals read differently.",
            visibleWhen: .init("tcRefType", equals: .choice("INT")), models: advancedModels),
        MeterSetting(
            id: "tcCheck", label: "Open Check", group: "Probe", header: "TEMP:TRAN:TC:CHEC",
            control: .toggle,
            help: "Checks for a broken thermocouple lead after each reading and reports overload if it is open. It slows readings because two measurements are made.",
            visibleWhen: probeIs("TC"), models: advancedModels),
        MeterSetting(
            id: "unit", label: "Units", group: "Units", header: "UNIT:TEMP",
            control: .choice([.init("C", "\u{00B0}C"), .init("F", "\u{00B0}F"), .init("K", "K")]),
            help: "The unit used for temperature readings. Reference-junction values are always in \u{00B0}C regardless."),
    ] + integrationSettings(prefix: "TEMP") + [
        MeterSetting(
            id: "autoZero", label: "Auto Zero", group: "Accuracy", header: "TEMP:ZERO:AUTO",
            control: .toggle,
            help: "When on, the meter measures its internal offset after every reading and subtracts it. It applies to 2-wire probes only; 4-wire measurements always use it."),
    ] + nullSettings(prefix: "TEMP", unit: .celsius) + [
        secondarySetting(header: "TEMP:SEC", choices: [
            secondaryOff, preMath, .init("SENS:DATA", "Sensor value"),
        ]),
    ])

    // MARK: Continuity and diode

    /// Continuity has no configurable `[SENSe:]` settings on this meter (the beeper is a
    /// system setting, not part of the function).
    static let continuity = FunctionProfile(function: .continuity, settings: [])

    /// Diode test has no configurable `[SENSe:]` settings on this meter.
    static let diode = FunctionProfile(function: .diode, settings: [])

    // MARK: DC ratio (manual pp. 58–59, 369–381)

    /// Ratio shares range, integration and input impedance with DC voltage. The reference
    /// input is always autoranged, auto zero is always on, and null is not available.
    static let dcRatio = FunctionProfile(function: .dcRatio, settings: [
        rangeSetting(
            header: "VOLT:RANG", steps: [0.1, 1, 10, 100, 1000], unit: .volt,
            help: "Range of the signal input; the reference input is always autoranged. Autorange picks the range for each reading."),
    ] + integrationSettings(prefix: "VOLT") + [
        MeterSetting(
            id: "inputZ", label: "Input Z", group: "Accuracy", header: "VOLT:IMP:AUTO",
            control: .toggle,
            help: "Input impedance. 10 MΩ on every range, or Auto: more than 10 GΩ on the 100 mV, 1 V and 10 V ranges to avoid loading high-impedance sources.",
            offLabel: "10 MΩ", onLabel: "Auto (Hi-Z)"),
        secondarySetting(header: "VOLT:RAT:SEC", choices: [
            secondaryOff, preMath, .init("SENS:DATA", "Input and reference"),
        ]),
    ])
}
