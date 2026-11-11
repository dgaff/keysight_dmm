import Foundation
import Testing
@testable import DMMKit

@Suite struct EngineeringFormatTests {
    @Test(arguments: [
        (-0.0000359, MeasurementUnit.volt, 7, "-35.90000 µV"),
        (1.2345678, .volt, 8, "1.2345678 V"),
        (0.1, .volt, 4, "100.0 mV"),
        (999.99996, .ohm, 7, "1.000000 kΩ"),
        (10_000_000, .ohm, 3, "10.0 MΩ"),
        (1.02e-7, .farad, 4, "102.0 nF"),
        (1e-13, .farad, 3, "0.100 pF"),         // below the smallest prefix: stays in pF
        (2.5e10, .hertz, 3, "25.0 GHz"),
        (23.456, .celsius, 4, "23.46 °C"),      // no prefixes on temperature
        (0.001234, .celsius, 3, "0.00123 °C"),
        (-12.5, .dBm, 3, "-12.5 dBm"),
        (0, .volt, 4, "0.000 V"),
        (0.5, .none, 3, "0.500"),
    ])
    func formats(value: Double, unit: MeasurementUnit, digits: Int, expected: String) {
        #expect(EngineeringNotation.string(value, unit: unit, significantDigits: digits) == expected)
    }

    @Test func overloadAndInvalid() {
        #expect(EngineeringNotation.string(Reading(raw: 9.9e37), unit: .volt) == "OVLD V")
        #expect(EngineeringNotation.string(Reading(raw: -9.9e37), unit: .volt) == "-OVLD V")
        #expect(EngineeringNotation.string(Reading(raw: 9.91e37), unit: .ohm) == "--- Ω")
    }

    @Test func compactDropsTrailingZeros() {
        #expect(EngineeringNotation.compact(0.1, unit: .volt) == "100 mV")
        #expect(EngineeringNotation.compact(1500, unit: .ohm) == "1.5 kΩ")
        #expect(EngineeringNotation.compact(1e-9, unit: .farad) == "1 nF")
        #expect(EngineeringNotation.compact(1000, unit: .volt) == "1 kV")
    }
}

@Suite struct EngineeringParseTests {
    @Test(arguments: [
        ("100m", MeasurementUnit.volt, 0.1),
        ("100 mV", .volt, 0.1),
        ("1e-3", .volt, 0.001),
        ("4.7k", .ohm, 4700),
        ("4.7 kΩ", .ohm, 4700),
        ("1 MOhm", .ohm, 1e6),
        ("1 mOhm", .ohm, 1e-3),      // milli vs mega is case-sensitive
        ("2meg", .ohm, 2e6),
        ("10uF", .farad, 1e-5),
        ("10 µF", .farad, 1e-5),
        ("100 pF", .farad, 1e-10),
        ("1 F", .farad, 1),
        ("2.5 MHz", .hertz, 2.5e6),
        ("20 ms", .second, 0.02),
        ("3 s", .second, 3),
        ("25 °C", .celsius, 25),
        ("-12.5 dBm", .dBm, -12.5),
        ("  0.5  ", .none, 0.5),
    ])
    func parses(text: String, unit: MeasurementUnit, expected: Double) throws {
        let value = try #require(EngineeringNotation.parse(text, unit: unit))
        #expect(abs(value - expected) <= abs(expected) * 1e-12)
    }

    @Test(arguments: [
        ("", MeasurementUnit.volt), ("abc", .volt), ("1,5", .volt), ("10 mA", .volt),
        ("5 k°C", .celsius), ("1 k", .none), ("nan", .volt), ("inf", .ohm),
    ])
    func rejects(text: String, unit: MeasurementUnit) {
        #expect(EngineeringNotation.parse(text, unit: unit) == nil)
    }

    @Test func formatThenParseRoundTrips() throws {
        for value in [1.234e-9, 4.7e-6, 0.0123, 1.5, 220, 4_700, 1.0e6, 3.3e9] {
            let text = EngineeringNotation.string(value, unit: .ohm, significantDigits: 9)
            let back = try #require(EngineeringNotation.parse(text, unit: .ohm))
            #expect(abs(back - value) <= value * 1e-8)
        }
    }
}

@Suite struct SCPIValueTests {
    @Test func numbersAreBareAndRoundTrip() {
        for value in [0.1, 1e-6, 100e-3, 1000, 1.0e9, -0.000_002, 3.0e-12] {
            let text = SCPIValue.number(value)
            #expect(Double(text) == value)
            #expect(text.allSatisfy { "0123456789.e-+".contains($0) })
        }
    }

    @Test func parsesInstrumentFormats() {
        #expect(SCPIValue.parseDouble("+1.00520000E+03\n") == 1005.2)
        #expect(SCPIValue.parseInt("+1.00000000E+03") == 1000)
        #expect(SCPIValue.parseInt("50000") == 50000)
        #expect(SCPIValue.parseBool("1") == true)
        #expect(SCPIValue.parseBool("OFF") == false)
        #expect(SCPIValue.parseString("\"VOLT:AC\"") == "VOLT:AC")
        #expect(SCPIValue.quoted("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(SCPIValue.parseDoubleList("-4.98748741E-01,-4.35163427E-01") == [-0.498748741, -0.435163427])
        #expect(SCPIValue.parseDoubleList("") == [])
        #expect(SCPIValue.parseDoubleList("1,x") == nil)
    }

    @Test func decodesReal64BothByteOrders() {
        let values = [1.5, -2.25e-6, 9.9e37]
        var big = Data(), little = Data()
        for v in values {
            withUnsafeBytes(of: v.bitPattern.bigEndian) { big.append(contentsOf: $0) }
            withUnsafeBytes(of: v.bitPattern.littleEndian) { little.append(contentsOf: $0) }
        }
        #expect(SCPIValue.parseReal64(big, bigEndian: true) == values)
        #expect(SCPIValue.parseReal64(little, bigEndian: false) == values)
        #expect(SCPIValue.parseReal64(big.dropLast()) == nil)
        // A sliced Data with a non-zero start index must decode too.
        #expect(SCPIValue.parseReal64(big.suffix(16)) == Array(values.suffix(2)))
    }

    @Test func readingSentinels() {
        #expect(Reading(raw: 9.9e37).status == .overload)
        #expect(Reading(raw: -9.9e37).value == -.infinity)
        #expect(Reading(raw: 9.91e37).status == .invalid)
        #expect(Reading(raw: 1000).status == .valid)
        #expect(Reading(response: "+9.90000000E+37")?.status == .overload)
    }

    @Test func errorQueueEntries() {
        #expect(InstrumentError(response: "-113,\"Undefined header\"") == InstrumentError(code: -113, message: "Undefined header"))
        #expect(InstrumentError(response: "+0,\"No error\"")?.code == 0)
        #expect(InstrumentError(response: "garbage") == nil)
    }

    @Test func identityAndFunctionParsing() {
        let id = InstrumentIdentity(idn: "Keysight Technologies,34470A,MY64017466,A.03.03-03.15-03.03-00.52-05-02")
        #expect(id?.truevoltModel == .m34470A)
        #expect(id?.serialNumber == "MY64017466")
        #expect(InstrumentIdentity(idn: "nonsense") == nil)
        for function in MeasurementFunction.allCases {
            #expect(MeasurementFunction(scpiResponse: "\"\(function.scpi)\"") == function)
        }
        #expect(MeasurementFunction(scpiResponse: "\"VOLT:DC\"") == .dcVoltage)
    }
}
