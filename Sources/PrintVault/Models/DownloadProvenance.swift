import Foundation

// MARK: - Extracted Download Provenance

public struct DownloadProvenance: Sendable, Equatable {
    public let sourceURL: String?
    public let designer: String?
    public let license: String?
    public let rawWhereFroms: [String]

    public init(
        sourceURL: String? = nil,
        designer: String? = nil,
        license: String? = nil,
        rawWhereFroms: [String] = []
    ) {
        self.sourceURL = sourceURL
        self.designer = designer
        self.license = license
        self.rawWhereFroms = rawWhereFroms
    }

    public var isEmpty: Bool {
        sourceURL == nil && designer == nil && license == nil
    }
}
