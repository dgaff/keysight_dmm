import Foundation

/// Factory-default values and limits for the settings `SimulatedMeter` understands,
/// taken from the 34470A column of the manual (with the DIG option, as on the bench
/// meter). The value strings are exactly what the real meter answers.
///
/// Keys are canonical headers: short form, no `SENS:` and no `:DC` node, and with the
/// pairs the meter treats as one parameter folded together (`FRES:` into `RES:`, the
/// period gate/range/timeout into `FREQ:`, `FRTD` into `RTD`, `FTH` into `THER`). See
/// `SimulatedMeter.canonical(_:)`.
///
/// Numeric entries carry `min`/`max` (answers to `HEADER? MIN` / `MAX`; the value is the
/// factory default, answered to `DEF`). Entries without limits are booleans (`0`/`1`),
/// bare mnemonics, or quoted strings.
extension SimulatedMeter {
    typealias DefaultEntry = (value: String, min: Double?, max: Double?)

    static let defaults: [String: DefaultEntry] = {
        var table: [String: DefaultEntry] = [:]

        func number(_ header: String, _ value: Double, _ min: Double, _ max: Double) {
            table[header] = (formatNumber(value), min, max)
        }
        func flag(_ header: String, _ on: Bool = false) { table[header] = (on ? "1" : "0", nil, nil) }
        func mnemonic(_ header: String, _ value: String) { table[header] = (value, nil, nil) }
        func quoted(_ header: String, _ value: String = "OFF") { table[header] = ("\"\(value)\"", nil, nil) }

        func range(_ prefix: String, _ value: Double, _ min: Double, _ max: Double) {
            number("\(prefix):RANG", value, min, max)
            flag("\(prefix):RANG:AUTO", true)
        }
        func integration(_ prefix: String) {
            flag("\(prefix):APER:ENAB")
            number("\(prefix):NPLC", 10, 0.001, 100)
            number("\(prefix):APER", 0.1, 20e-6, 1)
        }
        func null(_ prefix: String, limit: Double, autoOn: Bool = false) {
            flag("\(prefix):NULL")
            number("\(prefix):NULL:VAL", 0, -limit, limit)
            flag("\(prefix):NULL:VAL:AUTO", autoOn)
        }

        // DC voltage (also DC ratio's range, integration and input impedance)
        range("VOLT", 1000, 0.1, 1000)
        integration("VOLT")
        flag("VOLT:ZERO:AUTO", true)
        flag("VOLT:IMP:AUTO")
        null("VOLT", limit: 1200)
        quoted("VOLT:SEC")
        quoted("VOLT:RAT:SEC")

        // AC voltage
        range("VOLT:AC", 10, 0.1, 1000)
        number("VOLT:AC:BAND", 20, 3, 200)
        null("VOLT:AC", limit: 1200)
        quoted("VOLT:AC:SEC")

        // DC current
        number("CURR:TERM", 3, 3, 10)
        range("CURR", 1, 1e-6, 3)
        mnemonic("CURR:SWIT:MODE", "CONT")
        integration("CURR")
        flag("CURR:ZERO:AUTO", true)
        null("CURR", limit: 12, autoOn: true)
        quoted("CURR:SEC")

        // AC current
        number("CURR:AC:TERM", 3, 3, 10)
        range("CURR:AC", 1, 1e-4, 3)
        number("CURR:AC:BAND", 20, 3, 200)
        null("CURR:AC", limit: 12, autoOn: true)
        quoted("CURR:AC:SEC")

        // Resistance (4-wire shares everything with 2-wire except auto zero, which only 2-wire has)
        range("RES", 1000, 100, 1e9)
        integration("RES")
        flag("RES:ZERO:AUTO", true)
        flag("RES:OCOM")
        flag("RES:POW:LIM")
        null("RES", limit: 1.2e9)
        quoted("RES:SEC")

        // Frequency and period
        range("FREQ:VOLT", 10, 0.1, 1000)
        number("FREQ:RANG:LOW", 20, 3, 200)
        number("FREQ:APER", 0.1, 0.001, 1)
        flag("FREQ:TIM:AUTO")
        null("FREQ", limit: 1.2e6)
        quoted("FREQ:SEC")
        null("PER", limit: 1.2)
        quoted("PER:SEC")

        // Capacitance
        range("CAP", 1e-6, 1e-9, 1e-4)
        null("CAP", limit: 1.2e-4)
        quoted("CAP:SEC")

        // Temperature
        mnemonic("TEMP:TRAN:TYPE", "FRTD")
        number("TEMP:TRAN:RTD:RES", 100, 49, 2100)
        flag("TEMP:TRAN:RTD:OCOM")
        flag("TEMP:TRAN:RTD:POW:LIM")
        flag("TEMP:TRAN:THER:POW:LIM")
        mnemonic("TEMP:TRAN:TC:TYPE", "J")
        mnemonic("TEMP:TRAN:TC:RJUN:TYPE", "INT")
        number("TEMP:TRAN:TC:RJUN", 0, -20, 80)
        number("TEMP:TRAN:TC:RJUN:OFFS:ADJ", 0, -20, 20)
        flag("TEMP:TRAN:TC:CHEC")
        integration("TEMP")
        flag("TEMP:ZERO:AUTO", true)
        null("TEMP", limit: 1e15)
        quoted("TEMP:SEC")
        mnemonic("UNIT:TEMP", "C")

        // Sampling, triggering and data format (used by acquisitions)
        mnemonic("SAMP:SOUR", "IMM")
        number("SAMP:TIM", 1, 1e-3, 3600)
        number("SAMP:COUN", 1, 1, 1e9)
        number("SAMP:COUN:PRET", 0, 0, 49_999)
        number("TRIG:LEV", 0, -1000, 1000)
        number("TRIG:COUN", 1, 1, 1e6)
        mnemonic("TRIG:SOUR", "IMM")
        mnemonic("TRIG:SLOP", "NEG")
        number("TRIG:DEL", 160e-6, 0, 3600)
        flag("TRIG:DEL:AUTO", true)
        mnemonic("FORM:BORD", "NORM")

        // Terminals answer "+3" / "+10" on the real meter.
        table["CURR:TERM"]?.value = "+3"
        table["CURR:AC:TERM"]?.value = "+3"
        return table
    }()

    /// `%+.8E`, the meter's number format (`+1.00000000E-01`).
    static func formatNumber(_ value: Double) -> String {
        String(format: "%+.8E", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// Folds headers the meter treats as one parameter onto a single key, and drops the
    /// optional `SENS:` / `:DC` nodes.
    static func canonical(_ header: String) -> String {
        var key = header
        if key.hasPrefix("SENS:") { key.removeFirst(5) }
        for (long, short) in [("VOLT:DC:", "VOLT:"), ("CURR:DC:", "CURR:")] where key.hasPrefix(long) {
            key = short + key.dropFirst(long.count)
        }
        if key.hasPrefix("FRES:") { key = "RES:" + key.dropFirst(5) }
        // Period shares range, gate time and timeout with frequency; null and secondary are separate.
        if key.hasPrefix("PER:"), !key.hasPrefix("PER:NULL"), !key.hasPrefix("PER:SEC") {
            key = "FREQ:" + key.dropFirst(4)
        }
        if key.hasPrefix("TEMP:TRAN:FRTD:") { key = "TEMP:TRAN:RTD:" + key.dropFirst(15) }
        if key.hasPrefix("TEMP:TRAN:FTH:") { key = "TEMP:TRAN:THER:" + key.dropFirst(14) }
        return key
    }
}
