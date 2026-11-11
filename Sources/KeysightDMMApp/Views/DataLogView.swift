import DMMKit
import Observation
import SwiftUI

/// The log setup, kept by the window so it survives switching pages.
@MainActor
@Observable
final class LogSetup {
    enum Pacing: Hashable { case fastest, custom }
    enum StopMode: Hashable { case manual, samples, duration }
    enum StartMode: Hashable { case immediate, rising, falling }

    var name = ""
    var nameEdited = false
    var pacing = Pacing.custom
    var intervalText = "1 s"
    var stopMode = StopMode.samples
    var samplesText = "100"
    var durationText = "1 min"
    var startMode = StartMode.immediate
    var limitsOn = false
    var lowerText = ""
    var upperText = ""
    var notify = false
    /// The run a notification was already posted for.
    var notifiedRun: UUID?

    // MARK: Parsed values

    var intervalSeconds: Double? {
        guard pacing == .custom, let value = DurationText.parse(intervalText), value > 0 else { return nil }
        return value
    }

    var sampleCount: Int? {
        guard let count = Int(samplesText.trimmingCharacters(in: .whitespaces)), count >= 1 else { return nil }
        return count
    }

    var durationSeconds: Double? {
        guard let value = DurationText.parse(durationText), value >= 0 else { return nil }
        return value
    }

    var stop: AcquisitionPlan.Stop? {
        switch stopMode {
        case .manual: .manual
        case .samples: sampleCount.map { .samples($0) }
        case .duration: durationSeconds.map { .duration($0) }
        }
    }

    var plan: AcquisitionPlan? {
        let pace: AcquisitionPlan.Pacing
        switch pacing {
        case .fastest: pace = .fastest
        case .custom:
            guard let seconds = intervalSeconds else { return nil }
            pace = .interval(seconds)
        }
        guard let stop else { return nil }
        let trigger: AcquisitionPlan.Trigger = switch startMode {
        case .immediate: .immediate
        case .rising: .external(rising: true)
        case .falling: .external(rising: false)
        }
        return AcquisitionPlan(pacing: pace, stop: stop, trigger: trigger)
    }

    /// Samples and duration the run will have, where both can be worked out.
    var estimate: (samples: Int?, duration: Double?) {
        let interval = intervalSeconds
        switch stop {
        case .samples(let count)?:
            return (count, interval.map { Double(count - 1) * $0 })
        case .duration(let seconds)?:
            guard let interval else { return (nil, seconds) }
            return (Int((seconds / interval).rounded(.down)) + 1, seconds)
        default:
            return (nil, nil)
        }
    }

    func limits(unit: MeasurementUnit) -> Limits {
        guard limitsOn else { return .none }
        return Limits(
            lower: EngineeringNotation.parse(lowerText, unit: unit),
            upper: EngineeringNotation.parse(upperText, unit: unit))
    }
}

/// Sets up and runs a meter-paced data log, and shows the run as it goes.
struct DataLogView: View {
    let controller: MeterController
    @Bindable var setup: LogSetup
    let showRecording: (Recording.ID) -> Void

    private var unit: MeasurementUnit { controller.log?.recording.unit ?? controller.unit }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                setupForm
                Divider()
                LogStartBar(controller: controller, plan: setup.plan, name: setup.name, kind: "log", purpose: .dataLog)
            }
            .frame(width: 340)
            Divider()
            LogRunArea(
                controller: controller, purpose: .dataLog, limits: setup.limits(unit: unit),
                idleMessage: "Set up the run on the left and press Start. The readings appear here as they are taken.",
                showRecording: showRecording,
                onAnalysis: { id, outside in notifyIfNeeded(id: id, outside: outside) })
        }
        .background(.background)
        .onAppear { refreshName() }
        .onChange(of: controller.isLogging) { _, running in if !running { setup.nameEdited = false; refreshName() } }
        .onChange(of: controller.function) { _, _ in refreshName() }
        .onChange(of: setup.notify) { _, on in if on { LimitNotifier.requestAuthorization() } }
    }

    private func refreshName() {
        if !setup.nameEdited { setup.name = controller.suggestedName("log") }
    }

    // MARK: Setup

    private var setupForm: some View {
        Form {
            Section("Name") {
                TextField("Name", text: Binding(get: { setup.name }, set: { setup.name = $0; setup.nameEdited = true }))
                    .labelsHidden()
            }
            Section("What is measured") {
                MeasuredSummary(controller: controller)
            }
            Section("Sample interval") {
                Picker("Interval", selection: $setup.pacing) {
                    Text("As fast as possible").tag(LogSetup.Pacing.fastest)
                    Text("Custom").tag(LogSetup.Pacing.custom)
                }
                if setup.pacing == .custom {
                    SetupEntry(label: "Every", text: $setup.intervalText, example: "100 ms", valid: setup.intervalSeconds != nil) {
                        if let seconds = setup.intervalSeconds { setup.intervalText = EngineeringNotation.compact(seconds, unit: .second) }
                    }
                    if let seconds = setup.intervalSeconds {
                        SetupHint("Every \(EngineeringNotation.compact(seconds, unit: .second)). Type a number with ms, s, min or h.")
                    }
                } else {
                    SetupHint("The meter picks the shortest interval its settings allow.")
                }
                if let minimum = controller.log?.info?.minimumInterval {
                    SetupHint("Shortest for the last run: \(EngineeringNotation.compact(minimum, unit: .second)). It depends on NPLC and auto zero.")
                }
            }
            Section("Stop") {
                Picker("Stop", selection: $setup.stopMode) {
                    Text("When I press Stop").tag(LogSetup.StopMode.manual)
                    Text("After a number of samples").tag(LogSetup.StopMode.samples)
                    Text("After a duration").tag(LogSetup.StopMode.duration)
                }
                switch setup.stopMode {
                case .samples:
                    SetupEntry(label: "Samples", text: $setup.samplesText, example: "500", valid: setup.sampleCount != nil)
                case .duration:
                    SetupEntry(label: "Duration", text: $setup.durationText, example: "10 min", valid: setup.durationSeconds != nil) {
                        if let seconds = setup.durationSeconds { setup.durationText = DurationText.format(seconds) }
                    }
                case .manual:
                    EmptyView()
                }
                estimateLine
            }
            Section("Start") {
                Picker("Start", selection: $setup.startMode) {
                    Text("Immediately").tag(LogSetup.StartMode.immediate)
                    Text("On a rising edge at Ext Trig").tag(LogSetup.StartMode.rising)
                    Text("On a falling edge at Ext Trig").tag(LogSetup.StartMode.falling)
                }
                if setup.startMode != .immediate {
                    SetupHint("The meter waits for a signal on the rear-panel Ext Trig input.")
                }
            }
            Section("Limits") {
                Toggle("Check readings against limits", isOn: $setup.limitsOn)
                if setup.limitsOn {
                    SetupEntry(label: "Lower", text: $setup.lowerText, example: "none", valid: setup.lowerText.isEmpty || EngineeringNotation.parse(setup.lowerText, unit: unit) != nil)
                    SetupEntry(label: "Upper", text: $setup.upperText, example: "none", valid: setup.upperText.isEmpty || EngineeringNotation.parse(setup.upperText, unit: unit) != nil)
                    SetupHint("In \(unit.symbol.isEmpty ? "the reading's unit" : unit.symbol), for example 4.9 or 5.1 \(unit.symbol). Leave one empty to check only the other.")
                    Toggle("Notify when a reading is out of limits", isOn: $setup.notify)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(controller.isLogging)
    }

    @ViewBuilder
    private var estimateLine: some View {
        let estimate = setup.estimate
        if setup.stopMode == .manual {
            SetupHint("The log runs until you press Stop.")
        } else if let samples = estimate.samples, let duration = estimate.duration {
            SetupHint("About \(samples) samples over \(DurationText.format(duration)).")
        } else if let samples = estimate.samples {
            SetupHint("\(samples) samples. The time depends on the interval the meter allows.")
        } else if let duration = estimate.duration {
            SetupHint("Lasts \(DurationText.format(duration)). The number of samples depends on the interval.")
        }
    }

    private func notifyIfNeeded(id: Recording.ID, outside: Int) {
        guard setup.notify, setup.limitsOn, outside > 0, setup.notifiedRun != id,
              controller.isLogging, controller.log?.recording.id == id else { return }
        setup.notifiedRun = id
        LimitNotifier.post(
            title: "Reading out of limits",
            body: "\(controller.log?.recording.name ?? "The data log") has a reading outside its limits.")
    }
}
