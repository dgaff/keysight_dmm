import AppKit
import DMMKit
import Foundation
import UniformTypeIdentifiers

/// Typed durations ("10 min", "2 h", "250 ms") and readable duration text.
enum DurationText {
    /// Suffixes in the order they are tried (longest first so "min" is not read as "m").
    private static let units: [(suffix: String, seconds: Double)] = [
        ("minutes", 60), ("minute", 60), ("mins", 60), ("min", 60),
        ("hours", 3600), ("hour", 3600), ("hrs", 3600), ("hr", 3600), ("h", 3600),
    ]

    /// Understands "10 min", "2 h", "1.5 hours", and anything `EngineeringNotation`
    /// reads as seconds ("2", "0.5 s", "100 ms", "250us"). Nil if it cannot tell.
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for (suffix, seconds) in units where lower.hasSuffix(suffix) {
            let number = lower.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            if let value = Double(number), value.isFinite { return value * seconds }
        }
        return EngineeringNotation.parse(trimmed, unit: .second)
    }

    /// "850 ms", "12.5 s", "2 min 30 s", "1 h 5 min".
    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "–" }
        if seconds < 60 { return EngineeringNotation.compact(seconds, unit: .second, significantDigits: 4) }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h" }
        return secs > 0 ? "\(minutes) min \(secs) s" : "\(minutes) min"
    }
}

/// Upper and lower limits in the reading's base unit.
struct Limits: Sendable, Hashable {
    var lower: Double?
    var upper: Double?

    static let none = Limits()
    var isEmpty: Bool { lower == nil && upper == nil }

    func isOutside(_ value: Double) -> Bool {
        if value.isNaN { return false }
        if let lower, value < lower { return true }
        if let upper, value > upper { return true }
        return false
    }

    func outsideCount(in values: [Double]) -> Int {
        guard !isEmpty else { return 0 }
        var count = 0
        for value in values where isOutside(value) { count += 1 }
        return count
    }
}

/// File sizes without locale-dependent formatting.
enum ByteText {
    static func format(_ bytes: Int) -> String {
        if bytes < 1000 { return "\(bytes) bytes" }
        let units = ["kB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1000
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        return EngineeringNotation.compact(value, unit: .none, significantDigits: 3) + " " + units[index]
    }
}

/// Save panel and file-name helpers shared by the export, files and screen pages.
@MainActor
enum FileSaving {
    static func chooseURL(suggestedName: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Writes off the main thread; returns an error description on failure.
    static func write(_ data: Data, to url: URL) async -> String? {
        await Task.detached {
            do {
                try data.write(to: url, options: .atomic)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
    }

    /// A name safe to use as a file name on macOS and in other tools.
    static func sanitized(_ name: String, fallback: String = "recording") -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.controlCharacters)
        let cleaned = name.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? fallback : cleaned
    }
}

