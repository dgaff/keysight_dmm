import Foundation

/// A file or folder on the meter's internal flash (`INT:\`) or a USB stick in the
/// front-panel port (`USB:\`).
public struct MeterFile: Sendable, Equatable, Identifiable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable {
        case folder
        /// Instrument state (`.sta`).
        case state
        /// Preferences (`.prf`).
        case preferences
        /// Readings saved as text (`.csv`).
        case data
        case other
    }

    public let name: String
    /// Folder the file is in, e.g. `INT:\` or `USB:\MyData`.
    public let folder: String
    public let kind: Kind
    public let size: Int

    /// Full path as the meter expects it.
    public var path: String { folder.hasSuffix("\\") ? folder + name : folder + "\\" + name }
    public var id: String { path }
}

public struct MeterFolderListing: Sendable, Equatable {
    public let folder: String
    public let bytesUsed: Int
    public let bytesFree: Int
    public let files: [MeterFile]
}

extension MeterFolderListing {
    /// Parses a `MMEM:CAT?` response:
    /// `+1000000000,+327168572,"command.exe,,375808","MyDCVMeas.sta,STAT,8192"`.
    public init?(response: String, folder: String) {
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstComma = text.firstIndex(of: ",") else { return nil }
        let afterFirst = text[text.index(after: firstComma)...]
        let secondEnd = afterFirst.firstIndex(of: ",") ?? afterFirst.endIndex
        guard let used = SCPIValue.parseInt(String(text[..<firstComma])),
              let free = SCPIValue.parseInt(String(afterFirst[..<secondEnd])) else { return nil }

        var files: [MeterFile] = []
        // The rest is a list of quoted "name,type,size" entries; names may contain commas,
        // so split each entry from the right.
        var rest = afterFirst[secondEnd...]
        while let open = rest.firstIndex(of: "\"") {
            let body = rest[rest.index(after: open)...]
            guard let close = body.firstIndex(of: "\"") else { break }
            let entry = body[..<close]
            rest = body[body.index(after: close)...]
            guard let sizeComma = entry.lastIndex(of: ",") else { continue }
            let beforeSize = entry[..<sizeComma]
            guard let typeComma = beforeSize.lastIndex(of: ",") else { continue }
            let name = String(beforeSize[..<typeComma])
            let type = beforeSize[beforeSize.index(after: typeComma)...].uppercased()
            let size = Int(entry[entry.index(after: sizeComma)...].trimmingCharacters(in: .whitespaces)) ?? 0
            let kind: MeterFile.Kind = switch type {
            case "FOLD": .folder
            case "STAT": .state
            case "PREF": .preferences
            case "ASC": .data
            default: .other
            }
            if name == "." || name == ".." { continue }
            files.append(MeterFile(name: name, folder: folder, kind: kind, size: size))
        }
        self.init(folder: folder, bytesUsed: used, bytesFree: free, files: files.sorted {
            ($0.kind == .folder ? 0 : 1, $0.name.lowercased()) < ($1.kind == .folder ? 0 : 1, $1.name.lowercased())
        })
    }
}

extension Multimeter {
    public static let internalRoot = "INT:\\"
    public static let usbRoot = "USB:\\"

    /// Lists a folder. Throws `SCPIError.instrument` if it does not exist (for example
    /// `USB:\` with no stick inserted).
    public func listFiles(in folder: String = Multimeter.internalRoot) async throws -> MeterFolderListing {
        // `;*OPC?` makes a failed listing answer "1" at once instead of staying silent
        // until the timeout (an execution error skips the query but not the rest of the line).
        let command = "MMEM:CAT? \(SCPIValue.quoted(folder));*OPC?"
        let response = try await session.exclusive { s -> String in
            let answer = try await s.rawQuery(command, timeout: .seconds(10))
            guard answer.hasSuffix(";1") else {
                let errors = try await s.rawDrainErrors()
                throw errors.isEmpty
                    ? SCPIError.malformedResponse(command: command, response: answer)
                    : SCPIError.instrument(errors, command: command)
            }
            return String(answer.dropLast(2))
        }
        guard let listing = MeterFolderListing(response: response, folder: folder) else {
            throw SCPIError.malformedResponse(command: command, response: response)
        }
        return listing
    }

    /// Copies a file from the meter to the Mac.
    public func download(_ path: String) async throws -> Data {
        let command = "MMEM:UPL? \(SCPIValue.quoted(path));*OPC?"
        return try await session.exclusive { s -> Data in
            do {
                return try await s.rawQueryBlock(command, timeout: .seconds(60))
            } catch SCPIError.malformedResponse {
                // No block came back, only the "1" from *OPC?: the meter refused the file.
                let errors = try await s.rawDrainErrors()
                throw errors.isEmpty ? SCPIError.timeout(command: command) : SCPIError.instrument(errors, command: command)
            }
        }
    }

    public func deleteFile(_ path: String) async throws {
        try await session.set("MMEM:DEL \(SCPIValue.quoted(path))")
    }

    /// Saves the current instrument state to a `.sta` file on the meter.
    public func storeState(to path: String) async throws {
        try await session.set("MMEM:STOR:STAT \(SCPIValue.quoted(path))")
    }

    /// Loads an instrument state file. This reconfigures the meter.
    public func loadState(from path: String) async throws {
        try await session.set("MMEM:LOAD:STAT \(SCPIValue.quoted(path))")
    }

    /// The front-panel display as a PNG image (`HCOP:SDUM:DATA?`).
    public func captureScreen() async throws -> Data {
        try await session.exclusive { s in
            try await s.rawSet("HCOP:SDUM:DATA:FORM PNG")
            return try await s.rawQueryBlock("HCOP:SDUM:DATA?", timeout: .seconds(20))
        }
    }
}
