import DMMKit
import SwiftUI

/// One setting: a control suited to its kind, and an info button explaining it.
struct SettingRow: View {
    let controller: MeterController
    let setting: MeterSetting
    let state: SettingState
    @State private var showInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(setting.label)
                Button { showInfo.toggle() } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("What this does, and the SCPI command behind it")
                .accessibilityLabel("About \(setting.label)")
                .popover(isPresented: $showInfo, arrowEdge: .leading) {
                    SettingInfoPopover(setting: setting)
                }
                Spacer(minLength: 8)
                inlineControl
            }
            blockControl
        }
        .padding(.vertical, 2)
    }

    // MARK: Controls

    /// Controls that sit on the label's line.
    @ViewBuilder
    private var inlineControl: some View {
        switch setting.control {
        case .steps(let listed, let unit):
            stepsPicker(listed: listed, unit: unit)
        case .toggle where isPlainToggle:
            Toggle(setting.label, isOn: boolBinding).labelsHidden().toggleStyle(.switch)
        case .choice(let choices), .quotedChoice(let choices):
            choicePicker(choices)
        default:
            EmptyView()
        }
    }

    /// Controls that need their own line.
    @ViewBuilder
    private var blockControl: some View {
        switch setting.control {
        case .steps:
            if let auto = setting.auto, auto.supportsOnce {
                Button(onceLabel) { Task { await controller.setAuto(setting, .once) } }
                    .controlSize(.small)
                    .help("Send \(auto.header) ONCE: the meter picks a value now and then holds it")
            }
        case .number(let unit):
            NumberField(controller: controller, setting: setting, state: state, unit: unit)
        case .toggle where !isPlainToggle:
            Picker(setting.label, selection: boolBinding) {
                Text(setting.offLabel).tag(false)
                Text(setting.onLabel).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        default:
            EmptyView()
        }
    }

    private var isPlainToggle: Bool { setting.offLabel == "Off" && setting.onLabel == "On" }

    private var onceLabel: String {
        setting.label.lowercased().contains("range") ? "Autorange once" : "\(setting.label) once"
    }

    // MARK: Steps

    private enum StepTag: Hashable {
        case auto
        case value(Double)
    }

    private func stepsPicker(listed: [Double], unit: MeasurementUnit) -> some View {
        let current = state.value.number
        var steps = state.allowedSteps ?? listed
        // A value the meter reports that is not in the list still needs an entry to show.
        if let current, !steps.contains(where: { Self.close($0, current) }) {
            steps.append(current)
            steps.sort()
        }
        let selection = Binding<StepTag>(
            get: {
                if setting.auto != nil, state.auto == true { return .auto }
                if let current, let match = steps.first(where: { Self.close($0, current) }) { return .value(match) }
                return .value(steps.first ?? 0)
            },
            set: { tag in
                Task {
                    switch tag {
                    case .auto: await controller.setAuto(setting, .on)
                    case .value(let v): await controller.apply(setting, .number(v))
                    }
                }
            }
        )
        return Picker(setting.label, selection: selection) {
            if let auto = setting.auto {
                Text(auto.label).tag(StepTag.auto)
                Divider()
            }
            ForEach(steps, id: \.self) { step in
                Text(EngineeringNotation.compact(step, unit: unit)).tag(StepTag.value(step))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }

    private static func close(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= 1e-9 * max(abs(a), abs(b), 1e-30)
    }

    // MARK: Toggle and choice

    private var boolBinding: Binding<Bool> {
        Binding(
            get: { state.value.bool ?? false },
            set: { new in Task { await controller.apply(setting, .bool(new)) } }
        )
    }

    private func choicePicker(_ choices: [MeterSetting.Choice]) -> some View {
        let current = state.value.choice
        let binding = Binding<String>(
            get: { current ?? choices.first?.scpi ?? "" },
            set: { new in Task { await controller.apply(setting, .choice(new)) } }
        )
        return Picker(setting.label, selection: binding) {
            if let current, !choices.contains(where: { $0.scpi == current }) {
                Text(current).tag(current)
            }
            ForEach(choices) { Text($0.label).tag($0.scpi) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }
}

/// A free number between the meter's limits, committed on Return.
private struct NumberField: View {
    let controller: MeterController
    let setting: MeterSetting
    let state: SettingState
    let unit: MeasurementUnit

    @State private var text = ""
    @State private var message: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(setting.label, text: $text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .monospaced))
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused, message == nil { sync() }
                }
            if let message {
                Text(message).font(.caption).foregroundStyle(.red)
            } else if let range = rangeText {
                Text("Allowed: \(range)").font(.caption).foregroundStyle(.secondary)
            }
            if let auto = setting.auto {
                Toggle(auto.label, isOn: autoBinding)
            }
        }
        .onAppear(perform: sync)
        .onChange(of: state) { _, _ in if !focused { sync() } }
    }

    private var autoBinding: Binding<Bool> {
        Binding(
            get: { state.auto ?? false },
            set: { on in Task { await controller.setAuto(setting, on ? .on : .off) } }
        )
    }

    private var rangeText: String? {
        guard let low = state.minimum, let high = state.maximum else { return nil }
        return "\(EngineeringNotation.compact(low, unit: unit)) to \(EngineeringNotation.compact(high, unit: unit))"
    }

    private func sync() {
        message = nil
        text = state.value.number.map { EngineeringNotation.compact($0, unit: unit) } ?? ""
    }

    private func commit() {
        guard let value = EngineeringNotation.parse(text, unit: unit) else {
            message = "That is not a number." + (rangeText.map { " Enter a value from \($0)." } ?? "")
            return
        }
        if let low = state.minimum, let high = state.maximum, value < low || value > high {
            message = "Out of range. Enter a value from \(rangeText ?? "")."
            return
        }
        message = nil
        Task { await controller.apply(setting, .number(value)) }
    }
}
