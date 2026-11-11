import Foundation
import Testing
@testable import DMMKit

@Suite struct RecordingTests {
    private let identity = InstrumentIdentity(manufacturer: "Keysight Technologies", model: "34470A", serialNumber: "MY0", firmware: "A.03.03")
    private let start = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15T08:00:00Z

    private func sample() -> Recording {
        Recording(
            name: "Test log", instrument: identity, function: .dcVoltage, unit: .volt,
            timing: .meterPaced(interval: 0.5), started: start,
            settings: [.init(label: "Range", value: "10 V")],
            values: [0.001234, 1.5, .infinity, -.infinity, .nan])
    }

    @Test func csvUsesBaseUnitsAndExplicitStatus() {
        let lines = RecordingExport.csv(sample()).split(separator: "\n").map(String.init)
        #expect(lines.contains("# Unit: V"))
        #expect(lines.contains("# Range: 10 V"))
        #expect(lines.contains("# Timing: paced by the meter, 0.5 s between samples"))
        let header = lines.firstIndex(of: "index,time_s,timestamp,value_V,status")!
        #expect(lines[header + 1] == "0,0.0,2027-01-15T08:00:00.000Z,0.001234,ok")
        #expect(lines[header + 2] == "1,0.5,2027-01-15T08:00:00.500Z,1.5,ok")
        #expect(lines[header + 3] == "2,1.0,2027-01-15T08:00:01.000Z,,overload+")
        #expect(lines[header + 4] == "3,1.5,2027-01-15T08:00:01.500Z,,overload-")
        #expect(lines[header + 5] == "4,2.0,2027-01-15T08:00:02.000Z,,invalid")
    }

    @Test func csvOptions() {
        var options = RecordingExport.CSVOptions()
        options.includeMetadata = false
        options.includeTimestamps = false
        options.delimiter = .semicolon
        var recording = sample()
        recording.unit = .ohm
        let lines = RecordingExport.csv(recording, options: options).split(separator: "\n").map(String.init)
        #expect(lines[0] == "index;time_s;value_Ohm;status")
        #expect(lines[1] == "0;0.0;0.001234;ok")
    }

    @Test func tinyAndHugeValuesKeepFullPrecision() {
        var recording = sample()
        recording.values = [1.0e-12, 123456789.12345678, -4.9406564584124654e-9]
        var options = RecordingExport.CSVOptions()
        options.includeMetadata = false
        options.includeTimestamps = false
        let rows = RecordingExport.csv(recording, options: options).split(separator: "\n").dropFirst()
        let parsed = rows.map { Double($0.split(separator: ",")[2])! }
        #expect(parsed == recording.values)
    }

    @Test func jsonRoundTripsIncludingOverloadAndNaN() throws {
        let original = sample()
        let restored = try RecordingExport.recording(fromJSON: RecordingExport.json(original))
        #expect(restored.name == original.name)
        #expect(restored.timing == original.timing)
        #expect(restored.started == original.started)
        #expect(restored.values.prefix(4) == original.values.prefix(4))
        #expect(restored.values[4].isNaN)
    }

    @Test func appTimedRecordingUsesStoredTimes() {
        var recording = Recording(name: "Live", instrument: identity, function: .resistance2W, unit: .ohm, timing: .appTimed, started: start)
        recording.append(Reading(raw: 100), at: start.addingTimeInterval(0.25))
        recording.append(Reading(raw: 9.9e37), at: start.addingTimeInterval(0.75))
        #expect(recording.time(at: 1) == 0.75)
        #expect(recording.duration == 0.75)
        #expect(recording.values[1] == .infinity)
        #expect(recording.statistics.count == 1)
        #expect(recording.statistics.excluded == 1)
    }
}
