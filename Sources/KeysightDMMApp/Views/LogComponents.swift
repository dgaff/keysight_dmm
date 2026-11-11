import DMMKit
import SwiftUI

/// Progress and outcome of the current or last run.
struct LogStatusView: View {
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
            } else if count == 0, case .level = log.plan.trigger {
                Text("Waiting for the input to cross the trigger level…")
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
struct ProgressBar: View {
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

// MARK: Shared setup pieces (Data Log and Digitize)

/// A labelled text field for a typed value; red when the text cannot be read.
struct SetupEntry: View {
    let label: String
    @Binding var text: String
    let example: String
    let valid: Bool
    var commit: (() -> Void)?

    var body: some View {
        LabeledContent(label) {
            TextField(label, text: $text, prompt: Text(example))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 130)
                .foregroundStyle(valid ? Color.primary : Color.red)
                .onSubmit { commit?() }
        }
    }
}

/// Small explanatory text under a setup control.
struct SetupHint: View {
    let text: String
    var color: Color = .secondary
    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
}

/// Read-only summary of the measurement settings a run will use.
struct MeasuredSummary: View {
    let controller: MeterController
    var note = "Change the function and its settings on the Measure page."

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(summary).font(.callout)
            SetupHint(note)
        }
    }

    private var summary: String {
        let notes = controller.settingNotes.map { "\($0.label) \($0.value)" }
        return ([controller.function.displayName] + notes).joined(separator: " · ")
    }
}

/// Start and Stop for a run, under a setup form.
struct LogStartBar: View {
    let controller: MeterController
    let plan: AcquisitionPlan?
    let name: String
    let kind: String
    let purpose: MeterController.LogState.Purpose

    var body: some View {
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
                    guard let plan else { return }
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    Task { await controller.startLog(plan, name: trimmed.isEmpty ? controller.suggestedName(kind) : trimmed, purpose: purpose) }
                } label: {
                    Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(plan == nil || controller.link != .connected || controller.isApplying)
            }
            if !controller.isLogging, plan == nil {
                SetupHint("Fill in the highlighted fields to start.")
            }
        }
        .padding(14)
    }
}

/// Status, chart, statistics and table of the run that `purpose` started; an
/// explanatory message while there is none.
struct LogRunArea: View {
    let controller: MeterController
    let purpose: MeterController.LogState.Purpose
    var limits = Limits.none
    let idleMessage: String
    let showRecording: (Recording.ID) -> Void
    var onAnalysis: (@MainActor (Recording.ID, Int) -> Void)?
    @State private var exportTarget: Recording?

    private var log: MeterController.LogState? {
        controller.log?.purpose == purpose ? controller.log : nil
    }

    /// Where the trigger fell, when samples from before it were kept.
    private var triggerSeconds: Double? {
        // Known only once the capture has finished: the meter keeps fewer pre-trigger
        // samples than asked for when the trigger comes early.
        guard let log, let info = log.info, let index = log.triggerIndex else { return nil }
        return Double(index) * info.interval
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let log {
                LogStatusView(log: log)
                if !log.isRunning, log.recording.count > 0 {
                    HStack {
                        Button("Export…") { exportTarget = log.recording }
                        Button("Show in Recordings") { showRecording(log.recording.id) }
                    }
                }
            }
            RecordingView(
                provider: { controller.log?.purpose == purpose ? controller.log?.recording : nil },
                limits: limits,
                emptyMessage: log == nil ? idleMessage : "Waiting for the first reading…",
                triggerSeconds: triggerSeconds,
                onAnalysis: onAnalysis)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $exportTarget) { ExportSheet(recording: $0) }
    }
}
