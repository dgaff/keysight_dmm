import Foundation

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case measure, dataLog, recordings, digitize, files, screenCapture, console

    var id: String { rawValue }

    var title: String {
        switch self {
        case .measure: "Measure"
        case .dataLog: "Data Log"
        case .recordings: "Recordings"
        case .digitize: "Digitize"
        case .files: "Files"
        case .screenCapture: "Screen Capture"
        case .console: "Console"
        }
    }

    var symbol: String {
        switch self {
        case .measure: "gauge.with.dots.needle.33percent"
        case .dataLog: "list.bullet.rectangle"
        case .recordings: "waveform.path"
        case .digitize: "waveform.path.ecg"
        case .files: "folder"
        case .screenCapture: "camera.viewfinder"
        case .console: "terminal"
        }
    }

    var comingSoon: String {
        switch self {
        case .digitize: "Fast sampling with the digitizer is coming."
        default: ""
        }
    }

    static let work: [SidebarSection] = [.measure, .dataLog, .recordings, .digitize, .files, .screenCapture]

    /// Page named by `--page <name>` or `--page=<name>` (name: measure, datalog, recordings,
    /// digitize, files, screen, console), for testing. With `open --args`, use the `=` form:
    /// AppKit takes a bare second word to be a file to open and then shows no window.
    static var launchSelection: SidebarSection? {
        let arguments = CommandLine.arguments
        let name: String
        if let joined = arguments.first(where: { $0.hasPrefix("--page=") }) {
            name = String(joined.dropFirst("--page=".count))
        } else if let flag = arguments.firstIndex(of: "--page"), flag + 1 < arguments.count {
            name = arguments[flag + 1]
        } else {
            return nil
        }
        switch name.lowercased() {
        case "measure": return .measure
        case "datalog": return .dataLog
        case "recordings": return .recordings
        case "digitize": return .digitize
        case "files": return .files
        case "screen": return .screenCapture
        case "console": return .console
        default: return nil
        }
    }
}
