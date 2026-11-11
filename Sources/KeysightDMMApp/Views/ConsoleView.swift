import DMMKit
import SwiftUI
import AppKit

/// Traffic log with a command line: type a command, see the answer, get help from the
/// documented command catalogue.
struct ConsoleView: View {
    let controller: MeterController
    @State private var paused = false
    @State private var hideReadings = false
    @State private var input = ""
    @State private var status: String?
    @State private var sending = false
    @State private var historyPosition: Int?
    @State private var draft = ""
    @AppStorage("consoleHistory") private var historyText = ""
    @FocusState private var focused: Bool

    private static let historyLimit = 100

    private var history: [String] { historyText.isEmpty ? [] : historyText.components(separatedBy: "\n") }

    /// Traffic shown, optionally without the routine `READ?` polling and its answers.
    private var shown: [(id: Int, event: SCPITrafficEvent)] {
        var result: [(Int, SCPITrafficEvent)] = []
        var skipAnswer = false
        for (index, event) in controller.traffic.enumerated() {
            if hideReadings {
                if event.direction == .sent {
                    skipAnswer = event.text.uppercased().hasPrefix("READ?")
                    if skipAnswer { continue }
                } else if event.direction == .received, skipAnswer {
                    skipAnswer = false
                    continue
                }
            }
            result.append((index, event))
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            trafficLog
            Divider()
            footer
            Divider()
            commandArea
        }
        .background(.background)
        .onAppear { focused = true }
    }

    // MARK: Traffic

    private var trafficLog: some View {
        let lines = shown
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(lines, id: \.id) { line in
                        row(line.event).id(line.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: controller.traffic.count) { _, _ in
                if !paused, let last = shown.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .overlay {
                if lines.isEmpty {
                    Text(controller.traffic.isEmpty ? "Nothing has been sent yet." : "Only live readings so far.").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Toggle("Pause scrolling", isOn: $paused)
            Toggle("Hide live readings", isOn: $hideReadings)
                .help("Hides READ? and its answers, so what you type stands out")
            Spacer()
            Text("\(controller.traffic.count) lines").foregroundStyle(.secondary)
            Button("Copy all", action: copyAll)
                .disabled(controller.traffic.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Command line

    private var commandArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("→").font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                TextField("Command", text: $input, prompt: Text("Type a command, for example *IDN? or VOLT:NPLC?"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .focused($focused)
                    .autocorrectionDisabled()
                    .onSubmit(send)
                    .onKeyPress(.upArrow) { recall(older: true); return .handled }
                    .onKeyPress(.downArrow) { recall(older: false); return .handled }
                    .onChange(of: input) { _, new in
                        if let position = historyPosition, history.indices.contains(position), history[position] != new { historyPosition = nil }
                    }
                if sending { ProgressView().controlSize(.small) }
                Button("Send", action: send)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || sending || controller.link != .connected)
            }
            if let status {
                Text(status)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            suggestionList
            helpBlock
            Text("Live readings pause briefly while a typed command is sent. Commands that change calibration or security are blocked. Up and Down arrows recall earlier commands.")
                .font(.caption).foregroundStyle(.secondary)
            experimental
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var header: String {
        input.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
    }

    private var suggestions: [SCPICommandInfo] {
        let typed = input.trimmingCharacters(in: .whitespaces)
        guard typed.count >= 2, !typed.contains(" "), SCPICatalogue.shared.lookup(typed) == nil else { return [] }
        return CommandSuggestions.matches(for: typed, in: SCPICatalogue.shared.commands, limit: 8)
    }

    @ViewBuilder
    private var suggestionList: some View {
        let list = suggestions
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(list) { command in
                    Button {
                        input = CommandSuggestions.shortForm(of: command)
                        focused = true
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(command.command)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                            Text(command.summary)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 3).padding(.horizontal, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private var helpBlock: some View {
        if let command = SCPICatalogue.shared.lookup(input) {
            VStack(alignment: .leading, spacing: 2) {
                Text(command.summary).font(.callout)
                if let set = command.setSyntax { syntax(set) }
                if let query = command.querySyntax { syntax(query) }
                if let page = command.page { Text("Manual p. \(page)").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func syntax(_ text: String) -> some View {
        Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
    }

    // MARK: Experimental

    private struct Experimental: Identifiable {
        let insert: String
        let name: String
        let note: String
        var id: String { insert }
    }

    private static let experimental: [Experimental] = [
        .init(insert: "SYST:FPAN:KEYP ", name: "SYSTem:FPANel:KEYPress", note: "Simulates a front-panel key. Parameter names are unknown. Only try it while watching the meter."),
        .init(insert: "DISP:UPD", name: "DISPlay:UPDate", note: "Possibly forces a display refresh."),
        .init(insert: "DISP:MESS:CLE", name: "DISPlay:MESSage:CLEar", note: "Possibly clears a display message."),
        .init(insert: "SYST:AC:MODE?", name: "SYSTem:AC:MODE?", note: "Answers RMS; other values are unknown."),
        .init(insert: "VOLT:AC:MODE?", name: "VOLTage:AC:MODE?", note: "Answers RMS; other values are unknown."),
        .init(insert: "CURR:AC:MODE?", name: "CURRent:AC:MODE?", note: "Answers RMS; other values are unknown."),
        .init(insert: "DATA:FEED?", name: "DATA:FEED?", note: "Answers \"CALC\". Reading-memory management in the style of the 34410A."),
        .init(insert: "DATA:COPY ", name: "DATA:COPY", note: "Reading-memory management; arguments unknown."),
        .init(insert: "DATA:DEL", name: "DATA:DELete", note: "Reading-memory management; may erase stored readings."),
        .init(insert: "DATA:DATA?", name: "DATA[:DATA]?", note: "Reading-memory management."),
        .init(insert: "TEMP:TRAN:RTD:TYPE?", name: "TEMPerature:TRANsducer:RTD:TYPE?", note: "Answers 85 (RTD alpha type); a single value."),
        .init(insert: "TEMP:TRAN:FRTD:TYPE?", name: "TEMPerature:TRANsducer:FRTD:TYPE?", note: "Answers 85 (RTD alpha type); a single value."),
        .init(insert: "CAL:LFR?", name: "CALibration:LFRequency?", note: "Answers the line frequency used at calibration (60 on the bench meter)."),
        .init(insert: "SYST:GLOB:ERR?", name: "SYSTem:GLOBal:ERRor[:NEXT]?", note: "A second error queue shared across interfaces."),
        .init(insert: "SYST:GLOB:ERR:COUN?", name: "SYSTem:GLOBal:ERRor:COUNt?", note: "Number of entries in that queue."),
    ]

    private var experimental: some View {
        DisclosureGroup("Experimental: undocumented commands") {
            VStack(alignment: .leading, spacing: 6) {
                Text("These commands appear in the meter's own help list but not in the manual. They are untested; what they do is partly unknown. Inserting one does not send it.")
                    .font(.caption).foregroundStyle(.orange)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Self.experimental) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Button("Insert") {
                                    input = entry.insert
                                    focused = true
                                }
                                .controlSize(.small)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.name).font(.system(size: 12, design: .monospaced))
                                    Text(entry.note).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
            }
            .padding(.top, 4)
        }
        .font(.callout)
    }

    // MARK: Behaviour

    private func send() {
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !sending else { return }
        remember(command)
        input = ""
        historyPosition = nil
        sending = true
        status = "Sending \(command)…"
        Task {
            let outcome = await controller.sendConsole(command)
            status = outcome.isEmpty ? nil : outcome
            sending = false
            focused = true
        }
    }

    private func remember(_ command: String) {
        var list = history
        if list.last != command { list.append(command) }
        if list.count > Self.historyLimit { list.removeFirst(list.count - Self.historyLimit) }
        historyText = list.joined(separator: "\n")
    }

    private func recall(older: Bool) {
        let list = history
        guard !list.isEmpty else { return }
        if older {
            if let position = historyPosition {
                historyPosition = max(0, position - 1)
            } else {
                draft = input
                historyPosition = list.count - 1
            }
        } else {
            guard let position = historyPosition else { return }
            if position + 1 < list.count { historyPosition = position + 1 } else { historyPosition = nil; input = draft; return }
        }
        if let position = historyPosition { input = list[position] }
    }

    private func row(_ event: SCPITrafficEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.time(event.date)).foregroundStyle(.tertiary)
            Text(Self.marker(event.direction)).foregroundStyle(color(event.direction)).frame(width: 14)
            Text(event.text)
                .italic(event.direction == .note)
                .foregroundStyle(color(event.direction))
                .textSelection(.enabled)
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private func color(_ direction: SCPITrafficEvent.Direction) -> Color {
        switch direction {
        case .sent: .accentColor
        case .received: .primary
        case .note: .secondary
        }
    }

    private static func marker(_ direction: SCPITrafficEvent.Direction) -> String {
        switch direction {
        case .sent: "→"
        case .received: "←"
        case .note: "·"
        }
    }

    /// HH:MM:SS.mmm, built by hand so it never depends on the locale.
    private static func time(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        let ms = (c.nanosecond ?? 0) / 1_000_000
        let msText = ms < 10 ? "00\(ms)" : (ms < 100 ? "0\(ms)" : "\(ms)")
        return "\(two(c.hour ?? 0)):\(two(c.minute ?? 0)):\(two(c.second ?? 0)).\(msText)"
    }

    private func copyAll() {
        let text = controller.traffic.map { "\(Self.time($0.date)) \(Self.marker($0.direction)) \($0.text)" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Matching typed text against the command catalogue.
enum CommandSuggestions {
    /// Nodes of a catalogue header without optional parts, upper-cased in long form:
    /// `[SENSe:]VOLTage:DC:NPLCycles` → `VOLTAGE`, `DC`, `NPLCYCLES`.
    static func nodes(of command: String) -> [String] {
        var text = command.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        if text.hasSuffix("?") { text.removeLast() }
        return text.split(separator: ":").map { $0.uppercased() }
    }

    /// Commands whose nodes start with each typed node, in order (optional or skipped
    /// nodes allowed in between), best first.
    static func matches(for typed: String, in commands: [SCPICommandInfo], limit: Int) -> [SCPICommandInfo] {
        var text = typed.uppercased()
        let wantsQuery = text.hasSuffix("?")
        if wantsQuery { text.removeLast() }
        if text.hasPrefix(":") { text.removeFirst() }
        let typedNodes = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard !typedNodes.isEmpty, !text.isEmpty else { return [] }

        var scored: [(command: SCPICommandInfo, score: Int)] = []
        for command in commands {
            if wantsQuery, command.querySyntax == nil, !command.command.hasSuffix("?") { continue }
            let own = nodes(of: command.command)
            // Include the optional leading node (SENSe) too, so "sens:volt" also works.
            let withOptional = command.command.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            let all = Self.rawNodes(withOptional)
            var score = 0
            var position = 0
            var ok = true
            for node in typedNodes {
                guard let found = all[position...].firstIndex(where: { $0.hasPrefix(node) }) else { ok = false; break }
                score += found - position
                position = found + 1
            }
            guard ok else { continue }
            if own.first?.hasPrefix(typedNodes[0]) == true { score -= 2 }
            score += own.count
            scored.append((command, score))
        }
        return scored.sorted { $0.score < $1.score }.prefix(limit).map(\.command)
    }

    private static func rawNodes(_ command: String) -> [String] {
        var text = command
        if text.hasSuffix("?") { text.removeLast() }
        return text.split(separator: ":").map { $0.uppercased() }
    }

    /// Short form without optional nodes: `[SENSe:]VOLTage:DC:NPLCycles` → `VOLT:DC:NPLC`.
    static func shortForm(of info: SCPICommandInfo) -> String {
        let bare = info.command.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        let isQuery = bare.hasSuffix("?")
        let body = isQuery ? String(bare.dropLast()) : bare
        let short = body.split(separator: ":").map { node in
            String(node.filter { !$0.isLowercase })
        }.joined(separator: ":")
        return short + (isQuery ? "?" : "")
    }
}
