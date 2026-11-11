import DMMKit
import SwiftUI

/// The recordings made in this session: meter-paced logs and app-timed captures.
struct RecordingsView: View {
    let controller: MeterController
    @Binding var selection: Recording.ID?
    @State private var exportTarget: Recording?
    @State private var deleteTarget: Recording.ID?

    private var selected: Recording? {
        controller.recordings.first { $0.id == selection }
    }

    var body: some View {
        Group {
            if controller.recordings.isEmpty {
                ContentUnavailableView(
                    "No recordings yet",
                    systemImage: "waveform.path",
                    description: Text("Finish a data log, or press Record on the Measure page. Recordings are kept until you quit the app, so export the ones you want to keep."))
            } else {
                HStack(spacing: 0) {
                    list.frame(width: 300)
                    Divider()
                    if let recording = selected {
                        RecordingDetail(
                            controller: controller, recording: recording,
                            export: { exportTarget = recording },
                            delete: { deleteTarget = recording.id })
                            .id(recording.id)
                    } else {
                        Text("Choose a recording.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .background(.background)
        .onAppear { if selected == nil { selection = controller.recordings.first?.id } }
        .sheet(item: $exportTarget) { ExportSheet(recording: $0) }
        .confirmationDialog(
            "Delete this recording?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = deleteTarget {
                    if selection == id {
                        let remaining = controller.recordings.filter { $0.id != id }
                        selection = remaining.first?.id
                    }
                    controller.deleteRecording(id)
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("“\(controller.recordings.first { $0.id == deleteTarget }?.name ?? "")” will be removed. This cannot be undone.")
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(controller.recordings) { recording in
                RecordingRow(controller: controller, recording: recording)
                    .tag(recording.id)
                    .contextMenu {
                        Button("Export…") { exportTarget = recording }
                        Button("Delete…", role: .destructive) { deleteTarget = recording.id }
                    }
            }
        }
        .onDeleteCommand { deleteTarget = selection }
    }
}

private func timingText(_ recording: Recording) -> String {
    switch recording.timing {
    case .meterPaced: "Paced by meter"
    case .appTimed: "Timed by app"
    }
}

private struct RecordingRow: View {
    let controller: MeterController
    let recording: Recording
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if editing {
                TextField("Name", text: $draft)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, now in if !now { commit() } }
            } else {
                Text(recording.name).font(.headline).lineLimit(1)
                    .onTapGesture(count: 2) { beginEditing() }
            }
            Text("\(recording.function.displayName) · \(recording.count) readings · \(DurationText.format(recording.duration))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 4) {
                Text(recording.started, format: .dateTime.month(.abbreviated).day().hour().minute())
                Text("· \(timingText(recording))")
            }
            .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .contextMenu { Button("Rename") { beginEditing() } }
    }

    private func beginEditing() {
        draft = recording.name
        editing = true
        focused = true
    }

    private func commit() {
        guard editing else { return }
        editing = false
        let name = draft.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, name != recording.name { controller.renameRecording(recording.id, to: name) }
    }
}

private struct RecordingDetail: View {
    let controller: MeterController
    let recording: Recording
    let export: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recording.name).font(.title2.weight(.semibold))
                    Text(metadata).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Export…", action: export)
                Button("Delete…", role: .destructive, action: delete)
            }
            RecordingView(provider: { controller.recordings.first { $0.id == recording.id } })
            if !recording.settings.isEmpty {
                DisclosureGroup("Settings when recorded") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(Array(recording.settings.enumerated()), id: \.offset) { _, note in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(note.label).font(.caption).foregroundStyle(.secondary)
                                Text(note.value)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var metadata: String {
        let timing: String
        switch recording.timing {
        case .meterPaced(let interval):
            timing = "paced by the meter, \(EngineeringNotation.compact(interval, unit: .second)) between samples"
        case .appTimed:
            timing = "timed by the app as readings arrived (approximate)"
        }
        return "\(recording.function.displayName) · \(recording.count) readings over \(DurationText.format(recording.duration)) · \(timing)"
    }
}
