import Foundation

/// One documented SCPI command, from `Resources/scpi_commands.json` (extracted from the
/// Truevolt Operating and Service Guide).
public struct SCPICommandInfo: Sendable, Codable, Identifiable, Hashable {
    public struct Parameter: Sendable, Codable, Hashable {
        public let name: String
        public let type: String
        public let values: String?
        public let `default`: String?
        public let unit: String?
    }

    /// Canonical header as the manual prints it, e.g. `[SENSe:]VOLTage[:DC]:NPLC`.
    public let command: String
    public let subsystem: String
    public let setSyntax: String?
    public let querySyntax: String?
    public let summary: String
    public let parameters: [Parameter]
    public let appliesTo: [String]
    public let requiresOption: String?
    public let notes34470A: String?
    /// Printed page in the manual (equals the PDF page).
    public let page: Int?

    public var id: String { command }

    enum CodingKeys: String, CodingKey {
        case command, subsystem, summary, parameters, page
        case setSyntax = "set_syntax", querySyntax = "query_syntax"
        case appliesTo = "applies_to", requiresOption = "requires_option", notes34470A = "notes_34470A"
    }
}

/// The documented command set: lookup for help popovers and the console, and the
/// baseline that undocumented-command hunting diffs against.
public struct SCPICatalogue: Sendable {
    public let commands: [SCPICommandInfo]
    private let matchers: [(regex: NSRegularExpression, index: Int)]

    public static let shared: SCPICatalogue = {
        guard let url = resourceURL(), let data = try? Data(contentsOf: url),
              let commands = try? JSONDecoder().decode([SCPICommandInfo].self, from: data) else {
            assertionFailure("scpi_commands.json is missing or unreadable")
            return SCPICatalogue(commands: [])
        }
        return SCPICatalogue(commands: commands)
    }()

    public init(commands: [SCPICommandInfo]) {
        self.commands = commands
        matchers = commands.enumerated().compactMap { index, info in
            (try? NSRegularExpression(pattern: "^" + Self.pattern(for: info.command) + "$")).map { ($0, index) }
        }
    }

    /// Finds the entry for a header in any legal spelling: short or long form, any case,
    /// optional nodes present or not, with or without `?`, arguments or a leading colon
    /// (`volt:nplc?`, `:SENSE:VOLTAGE:DC:NPLC 10`).
    public func lookup(_ text: String) -> SCPICommandInfo? {
        var header = text.trimmingCharacters(in: .whitespaces)
        if let space = header.firstIndex(of: " ") { header = String(header[..<space]) }
        if header.hasSuffix("?") { header.removeLast() }
        if header.hasPrefix(":") { header.removeFirst() }
        header = header.uppercased()
        guard !header.isEmpty else { return nil }
        let whole = NSRange(header.startIndex..., in: header)
        for (regex, index) in matchers where regex.firstMatch(in: header, range: whole) != nil {
            return commands[index]
        }
        return nil
    }

    /// Regex source matching every legal spelling of a manual-style header.
    static func pattern(for command: String) -> String {
        var source = command.hasSuffix("?") ? String(command.dropLast()) : command
        if source.hasPrefix(":") { source.removeFirst() }
        var out = ""
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if character == "[" {
                out += "(?:"
                index = source.index(after: index)
            } else if character == "]" {
                out += ")?"
                index = source.index(after: index)
            } else if character.isLetter {
                let end = source[index...].firstIndex { !$0.isLetter } ?? source.endIndex
                let word = source[index..<end]
                let short = word.prefix { $0.isUppercase }
                let long = word.uppercased()
                out += short.isEmpty || short.count == word.count ? long : "(?:\(short)|\(long))"
                index = end
            } else {
                out += NSRegularExpression.escapedPattern(for: String(character))
                index = source.index(after: index)
            }
        }
        return out
    }

    /// Inside the .app the resource bundle is copied to Contents/Resources (keeping the
    /// bundle root clean for code signing); otherwise SwiftPM's own lookup applies.
    private static func resourceURL() -> URL? {
        let name = "scpi_commands", ext = "json"
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("KeysightDMM_DMMKit.bundle")
            if let bundle = Bundle(url: bundled), let url = bundle.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        return Bundle.module.url(forResource: name, withExtension: ext)
    }
}
