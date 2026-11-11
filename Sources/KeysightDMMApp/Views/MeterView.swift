import DMMKit
import SwiftUI

/// About the meter and its upkeep: facts, clock, self-test, states, reset, front panel.
struct MeterView: View {
    let controller: MeterController

    private enum Outcome: Equatable {
        case running
        case passed
        case failed([String])
        case couldNotRun
    }

    @State private var info: MeterInfo?
    @State private var loadingInfo = false
    @State private var infoLoaded = false
    @State private var selfTest: Outcome?
    @State private var autocal: Outcome?
    @State private var stateMessage: String?
    @State private var pendingRecall: Int?
    @State private var showStoreName = false
    @State private var storeName = ""
    @State private var confirmPreset = false
    @State private var presetMessage: String?
    @State private var clockMessage: String?
    @State private var displayText = ""
    @State private var displayMessage: String?
    @State private var now = Date()

    private var idle: Bool { controller.link == .connected && !controller.isLogging }

    var body: some View {
        Form {
            aboutSection
            clockSection
            maintenanceSection
            statesSection
            resetSection
            frontPanelSection
        }
        .formStyle(.grouped)
        .background(.background)
        .task { await loadInfo() }
        .task {
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .confirmationDialog(
            "Recall this state?", isPresented: Binding(get: { pendingRecall != nil }, set: { if !$0 { pendingRecall = nil } }),
            titleVisibility: .visible
        ) {
            Button("Recall", role: .destructive) {
                if let slot = pendingRecall {
                    Task { stateMessage = await controller.recallState(slot: slot) ? "Recalled state \(slot)." : "Could not recall state \(slot)." }
                }
                pendingRecall = nil
            }
            Button("Cancel", role: .cancel) { pendingRecall = nil }
        } message: {
            Text("This replaces the meter's current setup.")
        }
        .confirmationDialog("Reset measurement settings?", isPresented: $confirmPreset, titleVisibility: .visible) {
            Button("Preset", role: .destructive) {
                Task { presetMessage = await controller.preset() ? "The meter was returned to its preset settings." : "Could not preset the meter." }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This returns the measurement settings to their defaults. Stored states and network settings are kept.")
        }
        .alert("Save state to a file on the meter", isPresented: $showStoreName) {
            TextField("File name", text: $storeName)
            Button("Save") {
                let name = FileSaving.sanitized(storeName, fallback: "state")
                Task { stateMessage = await controller.storeState(named: name) ? "Saved \(name) on the meter's internal storage." : "Could not save the state file." }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The setup is stored in the meter's internal memory. It appears on the Files page.")
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            row("Model", "Keysight \(controller.identity.model)")
            row("Serial number", controller.identity.serialNumber)
            row("Firmware", controller.identity.firmware)
            row("Address", controller.endpointDescription)
            if let info {
                if let t = info.internalTemperature { row("Internal temperature", EngineeringNotation.compact(t, unit: .celsius, significantDigits: 3)) }
                if let u = info.uptime { row("On for", Self.uptimeText(u)) }
                if let f = info.lineFrequency { row("Line frequency", EngineeringNotation.compact(f, unit: .hertz, significantDigits: 3)) }
                if let terminals = info.terminals { row("Input terminals", Self.terminalsText(terminals)) }
                if let mac = info.macAddress { row("MAC address", Self.macText(mac)) }
                if let date = info.calibrationDate { row("Last calibration", date) }
                if let count = info.calibrationCount { row("Calibration count", String(count)) }
                if let date = info.autocalDate { row("Last autocalibration", date) }
                if let t = info.autocalTemperature { row("Temperature at autocalibration", EngineeringNotation.compact(t, unit: .celsius, significantDigits: 3)) }
                if let v = info.scpiVersion { row("SCPI version", v) }
            }
            if loadingInfo {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Asking the meter…").foregroundStyle(.secondary) }
            } else if infoLoaded, info == nil || info == MeterInfo() {
                SetupHint("The meter did not answer the detail queries. Only the identity above is shown.")
            }
        } header: {
            HStack {
                Text("About")
                Spacer()
                Button { Task { await loadInfo() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .controlSize(.small)
                    .disabled(loadingInfo || !idle)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).textSelection(.enabled) }
    }

    private func loadInfo() async {
        loadingInfo = true
        info = await controller.meterInfo()
        loadingInfo = false
        infoLoaded = true
    }

    /// "1 h 23 min", "2 d 4 h", "45 s".
    static func uptimeText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let days = total / 86_400, hours = (total % 86_400) / 3600, minutes = (total % 3600) / 60
        if days > 0 { return hours > 0 ? "\(days) d \(hours) h" : "\(days) d" }
        if hours > 0 { return "\(hours) h \(minutes) min" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(total) s"
    }

    static func terminalsText(_ code: String) -> String {
        switch code.trimmingCharacters(in: .whitespaces).uppercased() {
        case "FRON": "Front"
        case "REAR": "Rear"
        default: code
        }
    }

    /// Six pairs of hex digits joined with colons, from whatever separators the meter used.
    static func macText(_ raw: String) -> String {
        let hex = raw.filter(\.isHexDigit)
        guard hex.count == 12 else { return raw }
        var pairs: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            pairs.append(String(hex[index..<next]).uppercased())
            index = next
        }
        return pairs.joined(separator: ":")
    }

    // MARK: Clock

    private var clockSection: some View {
        Section("Clock") {
            row("Meter", info?.clock.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "Not read")
            row("This Mac", now.formatted(date: .abbreviated, time: .standard))
            HStack {
                Button("Set meter clock to this Mac's time") {
                    Task {
                        let ok = await controller.setClockToNow()
                        clockMessage = ok ? "The meter's clock was set." : "Could not set the meter's clock."
                        await loadInfo()
                    }
                }
                .disabled(!idle)
                if let clockMessage { Text(clockMessage).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    // MARK: Maintenance

    private var maintenanceSection: some View {
        Section("Maintenance") {
            maintenanceRow(
                button: "Run self-test", outcome: selfTest,
                explanation: "Checks the meter's internal hardware. It takes a few seconds, and live readings pause meanwhile.",
                couldNotRun: "The self-test could not run. A data log may be in progress, or the meter did not answer.") {
                selfTest = .running
                selfTest = Self.outcome(await controller.selfTest())
            }
            maintenanceRow(
                button: "Autocalibrate", outcome: autocal,
                explanation: "Compensates for drift with time and temperature. Nothing needs to be disconnected, and it does not change the stored calibration. It takes a few seconds and pauses readings.",
                couldNotRun: "Autocalibration could not run. A data log may be in progress, or this model does not support it.") {
                autocal = .running
                autocal = Self.outcome(await controller.autocalibrate())
            }
        }
    }

    private static func outcome(_ failures: [InstrumentError]?) -> Outcome {
        guard let failures else { return .couldNotRun }
        return failures.isEmpty ? .passed : .failed(failures.map(\.description))
    }

    private func maintenanceRow(
        button: String, outcome: Outcome?, explanation: String, couldNotRun: String,
        action: @escaping () async -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(button) { Task { await action() } }
                    .disabled(!idle || outcome == .running)
                if outcome == .running { ProgressView().controlSize(.small) }
                switch outcome {
                case .passed?: Label("Pass", systemImage: "checkmark.circle").foregroundStyle(.green)
                case .failed?: Label("Failed", systemImage: "xmark.octagon").foregroundStyle(.red)
                default: EmptyView()
                }
            }
            SetupHint(explanation)
            if case .failed(let list)? = outcome {
                ForEach(list, id: \.self) { Text($0).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            }
            if outcome == .couldNotRun { SetupHint(couldNotRun, color: .orange) }
        }
    }

    // MARK: States

    private var statesSection: some View {
        Section("States") {
            ForEach(0..<5, id: \.self) { slot in
                LabeledContent("State \(slot)") {
                    HStack {
                        Button("Save") {
                            Task { stateMessage = await controller.saveState(slot: slot) ? "Saved the current setup as state \(slot)." : "Could not save state \(slot)." }
                        }
                        Button("Recall…") { pendingRecall = slot }
                    }
                    .disabled(!idle)
                }
            }
            SetupHint("The meter keeps five setups you can return to. Saving over a slot replaces what was there.")
            Button("Save state to a file on the meter…") {
                storeName = "State"
                showStoreName = true
            }
            .disabled(!idle)
            if let stateMessage { Text(stateMessage).font(.callout).foregroundStyle(.secondary) }
        }
    }

    // MARK: Reset

    private var resetSection: some View {
        Section("Reset") {
            Button("Preset…") { confirmPreset = true }.disabled(!idle)
            SetupHint("Returns the measurement settings to their defaults. Stored states and network settings are kept.")
            if let presetMessage { Text(presetMessage).font(.callout).foregroundStyle(.secondary) }
        }
    }

    // MARK: Front panel

    private var frontPanelSection: some View {
        Section("Front panel") {
            if let url = info?.webInterfaceURL {
                VStack(alignment: .leading, spacing: 4) {
                    Link(destination: url) {
                        Label("Open the meter's web page", systemImage: "safari")
                    }
                    Text("Opens \(url.absoluteString) in your browser. The meter's own web interface mirrors the front panel and lets you press its keys.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Button("Beep") { Task { await controller.beep() } }.disabled(!idle)
            LabeledContent("Message") {
                HStack {
                    TextField("Message", text: $displayText, prompt: Text("Up to 40 characters"))
                        .labelsHidden()
                        .frame(maxWidth: 240)
                        .onChange(of: displayText) { _, new in if new.count > 40 { displayText = String(new.prefix(40)) } }
                        .onSubmit(showMessage)
                    Button("Show", action: showMessage)
                        .disabled(!idle || displayText.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Clear") {
                        Task { displayMessage = await controller.setDisplayText(nil) ? "Message cleared." : "Could not clear the message." }
                    }
                    .disabled(!idle)
                }
            }
            if let displayMessage { Text(displayMessage).font(.callout).foregroundStyle(.secondary) }
        }
    }

    private func showMessage() {
        let text = displayText.trimmingCharacters(in: .whitespaces)
        guard idle, !text.isEmpty else { return }
        Task { displayMessage = await controller.setDisplayText(text) ? "Message shown on the meter." : "Could not show the message." }
    }
}
