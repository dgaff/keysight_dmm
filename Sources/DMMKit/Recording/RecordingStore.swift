import Foundation

/// Keeps recordings on disk, one JSON file each, so they survive quitting the app.
public struct RecordingStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/KeysightDMM/Recordings`.
    public static var standard: RecordingStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return RecordingStore(directory: base.appendingPathComponent("KeysightDMM/Recordings", isDirectory: true))
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    /// All stored recordings, newest first. Files that cannot be read are skipped and
    /// their names returned, so the caller can say so rather than lose them silently.
    public func loadAll() -> (recordings: [Recording], unreadable: [String]) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var recordings: [Recording] = []
        var unreadable: [String] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let recording = try? RecordingExport.recording(fromJSON: data) {
                recordings.append(recording)
            } else {
                unreadable.append(file.lastPathComponent)
            }
        }
        return (recordings.sorted { $0.started > $1.started }, unreadable)
    }

    public func save(_ recording: Recording) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try RecordingExport.json(recording).write(to: url(for: recording.id), options: .atomic)
    }

    public func delete(_ id: UUID) throws {
        let file = url(for: id)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }
}
