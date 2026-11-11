import Foundation

/// Writes recordings to files other tools can read without guessing.
///
/// Values are always exported in the unprefixed SI unit with the unit named in the
/// column header (`value_V`), at full double precision, with "." as the decimal
/// separator whatever the Mac's locale. Scaling to mV or kΩ is left to the reader's
/// tool, so a file can never be off by a factor of a thousand.
public enum RecordingExport {
    public struct CSVOptions: Sendable, Equatable {
        public enum Delimiter: String, Sendable, CaseIterable {
            case comma = ",", semicolon = ";", tab = "\t"
        }

        /// `#`-prefixed lines describing the instrument and settings before the header row.
        public var includeMetadata = true
        /// Absolute ISO 8601 timestamp column in addition to elapsed seconds.
        public var includeTimestamps = true
        public var delimiter = Delimiter.comma

        public init() {}
    }

    public static func csv(_ recording: Recording, options: CSVOptions = CSVOptions()) -> String {
        let d = options.delimiter.rawValue
        var out = ""
        out.reserveCapacity(recording.count * 48 + 512)

        if options.includeMetadata {
            let id = recording.instrument
            out += "# \(recording.name)\n"
            out += "# Instrument: \(id.manufacturer) \(id.model), s/n \(id.serialNumber), firmware \(id.firmware)\n"
            out += "# Function: \(recording.function.displayName)\n"
            out += "# Unit: \(recording.unit.asciiSymbol.isEmpty ? "(none)" : recording.unit.asciiSymbol)\n"
            out += "# Started: \(timestamp(recording.started))\n"
            switch recording.timing {
            case .meterPaced(let interval):
                out += "# Timing: paced by the meter, \(SCPIValue.number(interval)) s between samples\n"
            case .appTimed:
                out += "# Timing: timed by the app as readings arrived (approximate)\n"
            }
            out += "# Samples: \(recording.count)\n"
            for note in recording.settings {
                out += "# \(note.label): \(note.value)\n"
            }
        }

        let unit = recording.unit.asciiSymbol
        var header = ["index", "time_s"]
        if options.includeTimestamps { header.append("timestamp") }
        header.append(unit.isEmpty ? "value" : "value_\(unit)")
        header.append("status")
        out += header.joined(separator: d) + "\n"

        for (index, value) in recording.values.enumerated() {
            let seconds = recording.time(at: index)
            out += "\(index)\(d)\(SCPIValue.number(seconds.isFinite ? seconds : 0))"
            if options.includeTimestamps {
                out += d + timestamp(recording.started.addingTimeInterval(seconds.isFinite ? seconds : 0))
            }
            // Overload and invalid readings have no number: leave the cell empty so
            // spreadsheets do not average a sentinel, and say why in the status column.
            if value.isNaN {
                out += "\(d)\(d)invalid\n"
            } else if value.isInfinite {
                out += "\(d)\(d)\(value < 0 ? "overload-" : "overload+")\n"
            } else {
                out += "\(d)\(SCPIValue.number(value))\(d)ok\n"
            }
        }
        return out
    }

    /// Complete, lossless form of a recording (also the app's own storage format).
    public static func json(_ recording: Recording, pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(recording)
    }

    public static func recording(fromJSON data: Data) throws -> Recording {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try decoder.decode(Recording.self, from: data)
    }

    /// ISO 8601 with milliseconds, in UTC.
    static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
    }
}
