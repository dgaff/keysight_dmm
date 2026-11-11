import Foundation

/// Parsed `*IDN?` response: `Keysight Technologies,34470A,MY64017466,A.03.03-03.15-03.03-00.52-05-02`.
public struct InstrumentIdentity: Sendable, Equatable, Hashable {
    public let manufacturer: String
    public let model: String
    public let serialNumber: String
    public let firmware: String

    public init(manufacturer: String, model: String, serialNumber: String, firmware: String) {
        self.manufacturer = manufacturer
        self.model = model
        self.serialNumber = serialNumber
        self.firmware = firmware
    }

    public init?(idn: String) {
        let fields = idn.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count == 4 else { return nil }
        self.init(manufacturer: fields[0], model: fields[1], serialNumber: fields[2], firmware: fields[3])
    }

    public var truevoltModel: TruevoltModel? { TruevoltModel(rawValue: model) }
}

/// The Truevolt family. The app is tested on the 34470A; the others are supported on a
/// best-effort basis through `Capabilities`.
public enum TruevoltModel: String, Sendable, CaseIterable {
    case m34460A = "34460A"
    case m34461A = "34461A"
    case m34465A = "34465A"
    case m34470A = "34470A"

    /// Display digits (6½ or 7½).
    public var digits: Double { self == .m34470A ? 7.5 : 6.5 }
}
