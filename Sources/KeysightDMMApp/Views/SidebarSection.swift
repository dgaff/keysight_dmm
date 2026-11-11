import Foundation

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case measure, dataLog, digitize, files, screenCapture, console

    var id: String { rawValue }

    var title: String {
        switch self {
        case .measure: "Measure"
        case .dataLog: "Data Log"
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
        case .digitize: "waveform.path.ecg"
        case .files: "folder"
        case .screenCapture: "camera.viewfinder"
        case .console: "terminal"
        }
    }

    var comingSoon: String {
        switch self {
        case .dataLog: "Timed logging into the meter's reading memory is coming."
        case .digitize: "Fast sampling with the digitizer is coming."
        case .files: "Browsing and saving files on the meter is coming."
        case .screenCapture: "Capturing the meter's display is coming."
        default: ""
        }
    }

    static let work: [SidebarSection] = [.measure, .dataLog, .digitize, .files, .screenCapture]
}
