import DMMKit
import Observation
import SwiftUI

/// The digitizer setup, kept by the window so it survives switching pages.
@MainActor
@Observable
final class DigitizeSetup {
    enum Pacing: Hashable { case fastest, custom }
    enum Trigger: Hashable { case immediate, externalRising, externalFalling, level }

    var name = ""
    var nameEdited = false
    var pacing = Pacing.fastest
    var rateText = "40 µs"
    var samplesText = "10000"
    var trigger = Trigger.immediate
    var levelText = "0"
    var levelRising = true
    var pretriggerText = "0"

    // MARK: Parsed values

    /// Seconds between samples from text that is an interval ("40 µs") or a rate ("25 kHz").
    static func parseInterval(_ text: String) -> Double? {
        let lower = text.trimmingCharacters(in: .whitespaces).lowercased()
        if lower.hasSuffix("hz") {
            guard let rate = EngineeringNotation.parse(text, unit: .hertz), rate > 0 else { return nil }
            return 1 / rate
        }
        guard let seconds = EngineeringNotation.parse(text, unit: .second), seconds > 0 else { return nil }
        return seconds
    }

    var typedAsRate: Bool { rateText.trimmingCharacters(in: .whitespaces).lowercased().hasSuffix("hz") }

    var intervalSeconds: Double? {
        pacing == .custom ? Self.parseInterval(rateText) : nil
    }

    var sampleCount: Int? {
        guard let count = Int(samplesText.trimmingCharacters(in: .whitespaces)), count >= 1 else { return nil }
        return count
    }

    var usesTrigger: Bool { trigger != .immediate }

    var pretriggerCount: Int? {
        let text = pretriggerText.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return 0 }
        guard let count = Int(text), count >= 0 else { return nil }
        return count
    }

    var pretriggerValid: Bool {
        guard usesTrigger else { return true }
        guard let pre = pretriggerCount else { return false }
        guard let total = sampleCount else { return true }
        return pre < total
    }

    func levelValue(unit: MeasurementUnit) -> Double? {
        EngineeringNotation.parse(levelText, unit: unit)
    }

    func plan(unit: MeasurementUnit) -> AcquisitionPlan? {
        let pace: AcquisitionPlan.Pacing
        switch pacing {
        case .fastest: pace = .fastest
        case .custom:
            guard let seconds = intervalSeconds else { return nil }
            pace = .interval(seconds)
        }
        guard let count = sampleCount, pretriggerValid else { return nil }
        let kind: AcquisitionPlan.Trigger
        switch trigger {
        case .immediate: kind = .immediate
        case .externalRising: kind = .external(rising: true)
        case .externalFalling: kind = .external(rising: false)
        case .level:
            guard let level = levelValue(unit: unit) else { return nil }
            kind = .level(level, rising: levelRising)
        }
        return AcquisitionPlan(pacing: pace, stop: .samples(count), trigger: kind, pretriggerSamples: usesTrigger ? (pretriggerCount ?? 0) : 0)
    }
}

/// Fast, usually triggered capture paced by the meter's sample timer.
struct DigitizeView: View {
    let controller: MeterController
    @Bindable var setup: DigitizeSetup
    let showRecording: (Recording.ID) -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                form
                Divider()
                LogStartBar(controller: controller, plan: setup.plan(unit: controller.unit), name: setup.name, kind: "capture", purpose: .digitize)
            }
            .frame(width: 340)
            Divider()
            LogRunArea(
                controller: controller, purpose: .digitize,
                idleMessage: "Set up the capture on the left and press Start. The readings appear here when it finishes or as they arrive.",
                showRecording: showRecording)
        }
        .background(.background)
        .onAppear { refreshName() }
        .onChange(of: controller.isLogging) { _, running in if !running { setup.nameEdited = false; refreshName() } }
        .onChange(of: controller.function) { _, _ in refreshName() }
    }

    private func refreshName() {
        if !setup.nameEdited { setup.name = controller.suggestedName("capture") }
    }

    // MARK: Setup

    private var form: some View {
        Form {
            Section("Name") {
                TextField("Name", text: Binding(get: { setup.name }, set: { setup.name = $0; setup.nameEdited = true }))
                    .labelsHidden()
            }
            Section("Measurement") {
                Button("Preset for fastest sampling") { Task { await controller.applyFastestSamplingPreset() } }
                    .disabled(controller.isApplying || controller.link != .connected)
                SetupHint("Sets a fixed range, turns auto zero off, uses the shortest integration time and removes the trigger delay. These are measurement settings; they also show on the Measure page.")
                MeasuredSummary(controller: controller)
            }
            Section("Sample rate") {
                Picker("Rate", selection: $setup.pacing) {
                    Text("As fast as possible").tag(DigitizeSetup.Pacing.fastest)
                    Text("Custom").tag(DigitizeSetup.Pacing.custom)
                }
                if setup.pacing == .custom {
                    SetupEntry(label: "Interval or rate", text: $setup.rateText, example: "40 µs or 25 kHz", valid: setup.intervalSeconds != nil) {
                        if let seconds = setup.intervalSeconds, !setup.typedAsRate {
                            setup.rateText = EngineeringNotation.compact(seconds, unit: .second)
                        }
                    }
                    if let seconds = setup.intervalSeconds {
                        SetupHint(setup.typedAsRate
                            ? "= \(EngineeringNotation.compact(seconds, unit: .second)) between samples."
                            : "= \(EngineeringNotation.compact(1 / seconds, unit: .hertz))")
                    } else {
                        SetupHint("Type an interval such as 40 µs or 1 ms, or a rate such as 25 kHz.")
                    }
                } else {
                    SetupHint("The meter uses the shortest interval its settings allow.")
                    if let minimum = controller.log?.info?.minimumInterval {
                        SetupHint("Last run: \(EngineeringNotation.compact(minimum, unit: .second)) (\(EngineeringNotation.compact(1 / minimum, unit: .hertz))).")
                    }
                }
            }
            Section("Samples") {
                SetupEntry(label: "Total samples", text: $setup.samplesText, example: "10000", valid: setup.sampleCount != nil)
                if let count = setup.sampleCount, let interval = setup.intervalSeconds {
                    SetupHint("About \(DurationText.format(Double(count - 1) * interval)) of signal.")
                } else if setup.sampleCount != nil {
                    SetupHint("The time depends on the interval the meter allows.")
                }
            }
            Section("Trigger") {
                Picker("Start", selection: $setup.trigger) {
                    Text("Immediately").tag(DigitizeSetup.Trigger.immediate)
                    Text("Rising edge at Ext Trig").tag(DigitizeSetup.Trigger.externalRising)
                    Text("Falling edge at Ext Trig").tag(DigitizeSetup.Trigger.externalFalling)
                    Text("Level").tag(DigitizeSetup.Trigger.level)
                }
                switch setup.trigger {
                case .immediate:
                    EmptyView()
                case .externalRising, .externalFalling:
                    SetupHint("The meter waits for a signal on the rear-panel Ext Trig input.")
                case .level:
                    levelControls
                }
                if setup.usesTrigger {
                    SetupEntry(label: "Pre-trigger samples", text: $setup.pretriggerText, example: "0", valid: setup.pretriggerValid)
                    if !setup.pretriggerValid {
                        SetupHint("Enter a whole number smaller than the total of \(setup.sampleCount.map(String.init) ?? "samples").", color: .red)
                    } else {
                        SetupHint("Samples kept from before the trigger. They count within the total.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(controller.isLogging)
    }

    @ViewBuilder
    private var levelControls: some View {
        let unit = controller.unit
        SetupEntry(label: "Level", text: $setup.levelText, example: unit.symbol.isEmpty ? "0" : "1 \(unit.symbol)", valid: setup.levelValue(unit: unit) != nil) {
            if let value = setup.levelValue(unit: unit) { setup.levelText = EngineeringNotation.compact(value, unit: unit) }
        }
        Picker("Slope", selection: $setup.levelRising) {
            Text("Rising").tag(true)
            Text("Falling").tag(false)
        }
        .pickerStyle(.segmented)
        SetupHint("The capture starts when the input crosses the level\(unit.symbol.isEmpty ? "" : " (in \(unit.symbol))"). Level triggering needs a fixed range.")
        if controller.states["range"]?.auto == true {
            Label("The range is on Auto. Choose a fixed range on the Measure page, or use the preset above.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
