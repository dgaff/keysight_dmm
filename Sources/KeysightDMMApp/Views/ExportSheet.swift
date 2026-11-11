import AppKit
import Charts
import DMMKit
import SwiftUI
import UniformTypeIdentifiers

/// Export of one recording as CSV or JSON, or its chart as PNG or PDF.
struct ExportSheet: View {
    enum Format: String, CaseIterable, Identifiable {
        case csv = "CSV", json = "JSON"
        var id: String { rawValue }
    }

    let recording: Recording
    @Environment(\.dismiss) private var dismiss
    @State private var format = Format.csv
    @State private var options = RecordingExport.CSVOptions()
    @State private var message: String?
    @State private var messageIsError = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export “\(recording.name)”").font(.title3.weight(.semibold))
            Text("\(recording.count) readings")
                .foregroundStyle(.secondary)

            Form {
                Section("Data") {
                    Picker("Format", selection: $format) {
                        ForEach(Format.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if format == .csv {
                        Toggle("Describe the instrument and settings in header lines", isOn: $options.includeMetadata)
                        Toggle("Add a timestamp column", isOn: $options.includeTimestamps)
                        Picker("Separator", selection: $options.delimiter) {
                            Text("Comma").tag(RecordingExport.CSVOptions.Delimiter.comma)
                            Text("Semicolon").tag(RecordingExport.CSVOptions.Delimiter.semicolon)
                            Text("Tab").tag(RecordingExport.CSVOptions.Delimiter.tab)
                        }
                    }
                    Text(unitSentence)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("Preview") {
                    ScrollView([.horizontal, .vertical]) {
                        Text(previewText)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 130)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            if let message {
                Label(message, systemImage: messageIsError ? "xmark.octagon" : "checkmark.circle")
                    .foregroundStyle(messageIsError ? Color.red : Color.secondary)
                    .font(.callout)
                    .textSelection(.enabled)
            }

            HStack {
                if format == .csv {
                    Button("Copy to clipboard") { Task { await copy() } }.disabled(busy)
                }
                Menu("Save chart as…") {
                    Button("PNG image…") { Task { await saveChart(png: true) } }
                    Button("PDF…") { Task { await saveChart(png: false) } }
                }
                .fixedSize()
                .disabled(busy)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save…") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            }
        }
        .padding(20)
        .frame(width: 560, height: 600)
    }

    // MARK: Text

    private var valueColumn: String {
        let unit = recording.unit.asciiSymbol
        return unit.isEmpty ? "value" : "value_\(unit)"
    }

    private var unitSentence: String {
        "Values are written in the base unit named in the column header (\(valueColumn)), never with prefixes such as m or k. For example, 5 millivolts appear as 0.005 under value_V."
    }

    /// The start of the file, made from the first few readings only.
    private var previewText: String {
        var head = recording
        head.values = Array(recording.values.prefix(4))
        head.times = Array(recording.times.prefix(4))
        let text: String
        switch format {
        case .csv:
            text = RecordingExport.csv(head, options: options)
        case .json:
            text = (try? RecordingExport.json(head, pretty: true)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Long header blocks would push the readings out of view: keep the first few lines.
        let headerCount = lines.prefix { $0.hasPrefix("#") }.count
        if headerCount > 4 {
            lines.replaceSubrange(3..<headerCount, with: ["# …"])
        }
        let shown = lines.prefix(10).joined(separator: "\n")
        return recording.count > 4 || lines.count > 10 ? shown + "\n…" : shown
    }

    // MARK: Actions

    private func save() async {
        let type: UTType = format == .csv ? .commaSeparatedText : .json
        let ext = format == .csv ? "csv" : "json"
        guard let url = FileSaving.chooseURL(suggestedName: "\(FileSaving.sanitized(recording.name)).\(ext)", type: type) else { return }
        busy = true
        defer { busy = false }
        let recording = recording
        let options = options
        let format = format
        let result: Result<Data, any Error> = await Task.detached {
            do {
                switch format {
                case .csv: return .success(Data(RecordingExport.csv(recording, options: options).utf8))
                case .json: return .success(try RecordingExport.json(recording, pretty: true))
                }
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let data):
            if let problem = await FileSaving.write(data, to: url) {
                report("Could not save the file: \(problem)", error: true)
            } else {
                report("Saved \(url.lastPathComponent).", error: false)
            }
        case .failure(let error):
            report("Could not prepare the file: \(error.localizedDescription)", error: true)
        }
    }

    private func copy() async {
        busy = true
        defer { busy = false }
        let recording = recording
        let options = options
        let text = await Task.detached { RecordingExport.csv(recording, options: options) }.value
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        report("Copied \(recording.count) readings as CSV.", error: false)
    }

    private func saveChart(png: Bool) async {
        let name = FileSaving.sanitized(recording.name)
        guard let url = FileSaving.chooseURL(suggestedName: "\(name).\(png ? "png" : "pdf")", type: png ? .png : .pdf) else { return }
        busy = true
        defer { busy = false }
        let input = ChartInput(recording: recording)
        let snapshot = await Task.detached(priority: .userInitiated) {
            ChartSnapshot.make(series: input.series, unit: input.unit, limits: .none)
        }.value
        let size = CGSize(width: 960, height: 540)
        let renderer = ImageRenderer(content: ExportedChart(title: recording.name, subtitle: subtitle, snapshot: snapshot).frame(width: size.width, height: size.height))
        renderer.scale = 2
        if png {
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                report("The chart could not be drawn.", error: true)
                return
            }
            if let problem = await FileSaving.write(data, to: url) {
                report("Could not save the chart: \(problem)", error: true)
            } else {
                report("Saved \(url.lastPathComponent).", error: false)
            }
        } else {
            var box = CGRect(origin: .zero, size: size)
            guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
                report("Could not create the PDF file.", error: true)
                return
            }
            renderer.render { _, draw in
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
                context.closePDF()
            }
            report("Saved \(url.lastPathComponent).", error: false)
        }
    }

    private var subtitle: String {
        "\(recording.function.displayName) · \(recording.count) readings · \(DurationText.format(recording.duration))"
    }

    private func report(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }
}

/// The chart as it is saved: titled, on white, at a fixed size.
private struct ExportedChart: View {
    let title: String
    let subtitle: String
    let snapshot: ChartSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            TrendPlot(snapshot: snapshot)
                .padding(.top, 8)
        }
        .padding(28)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}
