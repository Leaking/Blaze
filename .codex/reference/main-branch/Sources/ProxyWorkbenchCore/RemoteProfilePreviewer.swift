import Foundation

public struct RemoteProfilePreview: Hashable, Sendable {
    public var summary: ProfileImportSummary
    public var warningSamples: [String]

    public init(summary: ProfileImportSummary, warningSamples: [String]) {
        self.summary = summary
        self.warningSamples = warningSamples
    }
}

public enum RemoteProfilePreviewer {
    public static func preview(from url: URL) async throws -> RemoteProfilePreview {
        let text = try await RemoteProfileImporter.importText(from: url)
        let profile = ProfileParser.parse(text)
        return RemoteProfilePreview(
            summary: ProfileImportSummary(profile: profile, sourceText: text),
            warningSamples: profile.warnings.prefix(6).map { "line \($0.line): \($0.message)" }
        )
    }
}
