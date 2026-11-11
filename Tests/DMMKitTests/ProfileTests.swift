import Foundation
import Testing
@testable import DMMKit

@Suite struct ProfileTableTests {
    static let functions = MeasurementFunction.allCases

    @Test(arguments: functions)
    func settingsAreWellFormed(function: MeasurementFunction) {
        let profile = FunctionProfile.profile(for: function)
        #expect(profile.function == function)
        let ids = profile.settings.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate setting ids in \(function)")

        for setting in profile.settings {
            #expect(setting.header.wholeMatch(of: /[A-Z0-9:]+/) != nil, "bad header \(setting.header)")
            if let auto = setting.auto {
                #expect(auto.header.wholeMatch(of: /[A-Z0-9:]+/) != nil, "bad auto header \(auto.header)")
            }
            #expect(!setting.help.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(setting.id) has no help")
            #expect(!setting.label.isEmpty && !setting.group.isEmpty)

            switch setting.control {
            case .steps(let steps, _):
                #expect(!steps.isEmpty, "\(setting.id) has no steps")
                #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 < $1 }, "\(setting.id) steps not ascending")
            case .choice(let choices), .quotedChoice(let choices):
                #expect(!choices.isEmpty)
                #expect(Set(choices.map(\.scpi)).count == choices.count, "\(setting.id) repeats a choice")
            case .number, .toggle:
                break
            }

            if let condition = setting.visibleWhen {
                guard let target = profile.setting(condition.settingID) else {
                    Issue.record("\(function).\(setting.id) depends on missing setting \(condition.settingID)")
                    continue
                }
                #expect(target.id != setting.id)
                #expect(canHold(target.control, condition.equals), "\(setting.id) waits for a value \(target.id) cannot hold")
            }
        }
    }

    @Test func continuityAndDiodeHaveNoSettings() {
        #expect(FunctionProfile.profile(for: .continuity).settings.isEmpty)
        #expect(FunctionProfile.profile(for: .diode).settings.isEmpty)
    }

    @Test func everyOtherFunctionHasSettings() {
        for function in MeasurementFunction.allCases where function != .continuity && function != .diode {
            #expect(!FunctionProfile.profile(for: function).settings.isEmpty, "\(function) has an empty profile")
        }
    }

    private func canHold(_ control: MeterSetting.Control, _ value: SettingValue) -> Bool {
        switch (control, value) {
        case (.toggle, .bool): true
        case (.steps(let steps, _), .number(let v)): steps.contains(v)
        case (.number, .number): true
        case (.choice(let choices), .choice(let c)), (.quotedChoice(let choices), .choice(let c)):
            choices.contains { $0.scpi == c }
        default: false
        }
    }
}

@Suite struct ProfileSimulatorTests {
    private func connect() async throws -> (Multimeter, SimulatedMeter) {
        let sim = SimulatedMeter()
        return (try await Multimeter.connect(transport: sim), sim)
    }

    @Test(arguments: MeasurementFunction.allCases)
    func readSettingsSucceedsForEverySetting(function: MeasurementFunction) async throws {
        let (meter, sim) = try await connect()
        try await meter.setFunction(function)
        let profile = FunctionProfile.profile(for: function)
        let states = try await meter.readSettings(profile.settings)

        for setting in profile.settings {
            guard let state = states[setting.id] else {
                Issue.record("\(function).\(setting.id) (\(setting.header)) was not read")
                continue
            }
            if let auto = setting.auto {
                #expect(state.auto != nil, "\(setting.header) has no auto state (\(auto.header))")
            }
            if setting.isNumeric {
                let value = state.value.number
                #expect(value != nil)
                if let value, let low = state.minimum, let high = state.maximum {
                    #expect(low <= value && value <= high, "\(setting.header) = \(value) outside \(low)...\(high)")
                } else {
                    Issue.record("\(setting.header) lacks limits")
                }
            }
            if case .steps = setting.control {
                #expect(state.allowedSteps?.isEmpty == false, "\(setting.header) has no allowed steps")
            }
        }
        // Reading must not have provoked errors (a rejected query would sit in the queue).
        let leftover = try await meter.session.drainErrors()
        #expect(leftover.isEmpty, "\(function) left \(leftover) in the error queue")
        #expect(sim.received.isEmpty == false)
    }

    @Test func numericRoundTrip() async throws {
        let (meter, _) = try await connect()
        let nplc = try #require(FunctionProfile.dcVoltage.setting("nplc"))
        try await meter.apply(nplc, .number(1))
        let state = try await meter.readSettings([nplc])["nplc"]
        #expect(state?.value == .number(1))
    }

    @Test func fixingTheRangeTurnsAutorangeOff() async throws {
        let (meter, _) = try await connect()
        let range = try #require(FunctionProfile.dcVoltage.setting("range"))
        #expect(try await meter.readSettings([range])["range"]?.auto == true)
        try await meter.apply(range, .number(10))
        let state = try await meter.readSettings([range])["range"]
        #expect(state?.value == .number(10))
        #expect(state?.auto == false)
        try await meter.setAuto(range, .on)
        #expect(try await meter.readSettings([range])["range"]?.auto == true)
    }

    @Test func toggleRoundTrip() async throws {
        let (meter, sim) = try await connect()
        let autoZero = try #require(FunctionProfile.dcVoltage.setting("autoZero"))
        #expect(try await meter.readSettings([autoZero])["autoZero"]?.value == .bool(true))
        try await meter.apply(autoZero, .bool(false))
        #expect(try await meter.readSettings([autoZero])["autoZero"]?.value == .bool(false))
        try await meter.apply(autoZero, .bool(true))
        #expect(try await meter.readSettings([autoZero])["autoZero"]?.value == .bool(true))
        #expect(sim.received.contains("VOLT:ZERO:AUTO OFF"))
    }

    @Test func choiceRoundTrip() async throws {
        let (meter, _) = try await connect()
        let probe = try #require(FunctionProfile.temperature.setting("probe"))
        #expect(try await meter.readSettings([probe])["probe"]?.value == .choice("FRTD"))
        try await meter.apply(probe, .choice("TC"))
        #expect(try await meter.readSettings([probe])["probe"]?.value == .choice("TC"))
    }

    @Test func quotedChoiceRoundTrip() async throws {
        let (meter, sim) = try await connect()
        let secondary = try #require(FunctionProfile.dcVoltage.setting("secondary"))
        #expect(try await meter.readSettings([secondary])["secondary"]?.value == .choice("OFF"))
        try await meter.apply(secondary, .choice("CALC:DATA"))
        #expect(try await meter.readSettings([secondary])["secondary"]?.value == .choice("CALC:DATA"))
        try await meter.apply(secondary, .choice("PTP"))
        #expect(try await meter.readSettings([secondary])["secondary"]?.value == .choice("PTP"))
        #expect(sim.received.contains("VOLT:SEC \"PTP\""))
    }

    @Test func periodSharesGateTimeWithFrequency() async throws {
        let (meter, _) = try await connect()
        let freqGate = try #require(FunctionProfile.frequency.setting("gateTime"))
        let perGate = try #require(FunctionProfile.period.setting("gateTime"))
        try await meter.apply(freqGate, .number(1))
        #expect(try await meter.readSettings([perGate])["gateTime"]?.value == .number(1))
    }

    @Test func outOfRangeNumberIsRejectedAndLeavesValueAlone() async throws {
        let (meter, _) = try await connect()
        let nplc = try #require(FunctionProfile.dcVoltage.setting("nplc"))
        do {
            try await meter.apply(nplc, .number(1000))
            Issue.record("expected the meter to reject NPLC 1000")
        } catch let SCPIError.instrument(errors, _) {
            #expect(errors.first?.code == -222)
        }
        #expect(try await meter.readSettings([nplc])["nplc"]?.value == .number(10))
    }

    @Test func unknownHeaderStillQueuesUndefinedHeader() async throws {
        let (meter, _) = try await connect()
        // No answer (the query times out) and -113 is queued: the old behaviour.
        let answer = try await meter.session.queryIfSupported("BOGUS:THING?", timeout: .milliseconds(100))
        #expect(answer == nil)
        let known = try await meter.session.queryIfSupported("BOGUS:THING? MAX", timeout: .milliseconds(100))
        #expect(known == nil)
    }
}
