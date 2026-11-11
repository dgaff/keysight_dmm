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
    @State private var exportTarget: Recording?

    private var unit: MeasurementUnit { controller.log?.recording.unit ?? controller.unit }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                setupForm
                Divider()
                startBar
            }
            .frame(width: 340)
            Divider()
            runArea
        }
        .background(.background)
        .onAppear { refreshName() }
        .onChange(of: controller.isLogging) { _, running in if !running { setup.nameEdited = false; refreshName() } }
        .onChange(of: controller.function) { _, _ in refreshName() }
        .onChange(of: setup.notify) { _, on in if on { LimitNotifier.requestAuthorization() } }
        .sheet(item: $exportTarget) { ExportSheet(recording: $0) }
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
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary).font(.callout)
                    Text("Change the function and its settings on the Measure page.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Sample interval") {
                Picker("Interval", selection: $setup.pacing) {
                    Text("As fast as possible").tag(LogSetup.Pacing.fastest)
                    Text("Custom").tag(LogSetup.Pacing.custom)
                }
                if setup.pacing == .custom {
                    entry("Every", text: $setup.intervalText, example: "100 ms", valid: setup.intervalSeconds != nil) {
                        if let seconds = setup.intervalSeconds { setup.intervalText = EngineeringNotation.compact(seconds, unit: .second) }
                    }
                    if let seconds = setup.intervalSeconds {
                        hint("Every \(EngineeringNotation.compact(seconds, unit: .second)). Type a number with ms, s, min or h.")
                    }
                } else {
                    hint("The meter picks the shortest interval its settings allow.")
                }
                if let minimum = controller.log?.info?.minimumInterval {
                    hint("Shortest for the last run: \(EngineeringNotation.compact(minimum, unit: .second)). It depends on NPLC and auto zero.")
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
                    entry("Samples", text: $setup.samplesText, example: "500", valid: setup.sampleCount != nil)
                case .duration:
                    entry("Duration", text: $setup.durationText, example: "10 min", valid: setup.durationSeconds != nil) {
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
                    hint("The meter waits for a signal on the rear-panel Ext Trig input.")
                }
            }
            Section("Limits") {
                Toggle("Check readings against limits", isOn: $setup.limitsOn)
                if setup.limitsOn {
                    entry("Lower", text: $setup.lowerText, example: "none", valid: setup.lowerText.isEmpty || EngineeringNotation.parse(setup.lowerText, unit: unit) != nil)
                    entry("Upper", text: $setup.upperText, example: "none", valid: setup.upperText.isEmpty || EngineeringNotation.parse(setup.upperText, unit: unit) != nil)
                    hint("In \(unit.symbol.isEmpty ? "the reading's unit" : unit.symbol), for example 4.9 or 5.1 \(unit.symbol). Leave one empty to check only the other.")
                    Toggle("Notify when a reading is out of limits", isOn: $setup.notify)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(controller.isLogging)
    }

    private var summary: String {
        let notes = controller.settingNotes.map { "\($0.label) \($0.value)" }
        return ([controller.function.displayName] + notes).joined(separator: " · ")
    }

    private func entry(
        _ label: String, text: Binding<String>, example: String, valid: Bool, commit: (() -> Void)? = nil
    ) -> some View {
        LabeledContent(label) {
            TextField(label, text: text, prompt: Text(example))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 130)
                .foregroundStyle(valid ? Color.primary : Color.red)
                .onSubmit { commit?() }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var estimateLine: some View {
        let estimate = setup.estimate
        if setup.stopMode == .manual {
            hint("The log runs until you press Stop.")
        } else if let samples = estimate.samples, let duration = estimate.duration {
            hint("About \(samples) samples over \(DurationText.format(duration)).")
        } else if let samples = estimate.samples {
            hint("\(samples) samples. The time depends on the interval the meter allows.")
        } else if let duration = estimate.duration {
            hint("Lasts \(DurationText.format(duration)). The number of samples depends on the interval.")
        }
    }

    private var startBar: some View {
        VStack(spacing: 6) {
            if controller.isLogging {
                Button { controller.stopLog() } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button {
                    guard let plan = setup.plan else { return }
                    let name = setup.name.trimmingCharacters(in: .whitespaces)
                    Task { await controller.startLog(plan, name: name.isEmpty ? controller.suggestedName("log") : name) }
                } label: {
                    Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(setup.plan == nil || controller.link != .connected || controller.isApplying)
            }
            if !controller.isLogging, setup.plan == nil {
                hint("Fill in the highlighted fields to start.")
            }
        }
        .padding(14)
    }

    // MARK: Run

    private var runArea: some View {
        let limits = setup.limits(unit: unit)
        return VStack(alignment: .leading, spacing: 14) {
            if let log = controller.log {
                LogStatusView(log: log)
                if !log.isRunning, log.recording.count > 0 {
                    HStack {
                        Button("Export…") { exportTarget = log.recording }
                        Button("Show in Recordings") { showRecording(log.recording.id) }
                    }
                }
            }
            RecordingView(
                provider: { controller.log?.recording },
                limits: limits,
                emptyMessage: controller.log == nil
                    ? "Set up the run on the left and press Start. The readings appear here as they are taken."
                    : "Waiting for the first reading…",
                onAnalysis: { id, outside in notifyIfNeeded(id: id, outside: outside) })
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

/// Progress and outcome of the current or last run.
private struct LogStatusView: View {
    let log: MeterController.LogState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if log.isRunning {
                runningLine
                if let progress = log.progress {
                    ProgressBar(fraction: progress)
                }
            } else {
                outcomeLine
            }
            if let info = log.info {
                Text(intervalText(info)).font(.callout).foregroundStyle(.secondary)
                if info.autorangeOn {
                    notice("Autorange was on. If the range changes during the run, sample timing can slip. A fixed range is recommended for timed logging.",
                           symbol: "exclamationmark.triangle", color: .orange)
                }
            }
            if let failure = log.failure {
                notice(failure, symbol: "xmark.octagon", color: .red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func notice(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
            Text(text).textSelection(.enabled)
        }
        .font(.callout)
        .foregroundStyle(color)
    }

    private var count: Int { log.recording.count }

    private var collected: String {
        if let expected = log.info?.expectedCount { return "\(count) of \(expected) samples" }
        return "\(count) samples"
    }

    private var runningLine: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).frame(width: 16, height: 16)
            if log.info == nil {
                Text("Starting…")
            } else if count == 0, case .external = log.plan.trigger {
                Text("Waiting for the start signal on Ext Trig…")
            } else {
                Text("Collecting: \(collected) · \(DurationText.format(log.recording.duration)) elapsed")
            }
        }
        .font(.headline)
    }

    @ViewBuilder
    private var outcomeLine: some View {
        if log.failure != nil {
            Text("The run failed after \(collected).").font(.headline)
        } else {
            switch log.end {
            case .completed?:
                Label("Finished: \(collected) in \(DurationText.format(log.recording.duration)).", systemImage: "checkmark.circle")
                    .font(.headline)
            case .stopped?:
                Label("Stopped by you: \(collected) in \(DurationText.format(log.recording.duration)).", systemImage: "stop.circle")
                    .font(.headline)
            case .endedByInstrument?:
                Label("The meter stopped on its own after \(collected). Something may have been pressed on its front panel.", systemImage: "exclamationmark.circle")
                    .font(.headline)
            case nil:
                EmptyView()
            }
        }
    }

    private func intervalText(_ info: AcquisitionInfo) -> String {
        "Interval \(EngineeringNotation.compact(info.interval, unit: .second)) · shortest allowed \(EngineeringNotation.compact(info.minimumInterval, unit: .second))"
    }
}

/// A plain progress bar with a fixed height. (The system linear `ProgressView` stretched
/// the page vertically here.)
private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(.quaternary)
            .frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * max(0, min(1, fraction)))
                }
            }
            .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}
