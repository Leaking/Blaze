import Foundation

public struct ProfileImportSummary: Hashable, Sendable {
    public var sourceBytes: Int
    public var generalKeys: Int
    public var proxies: Int
    public var groups: Int
    public var rules: Int
    public var ruleSets: Int
    public var warnings: Int
    public var unsupportedSections: [String]

    public init(
        sourceBytes: Int,
        generalKeys: Int,
        proxies: Int,
        groups: Int,
        rules: Int,
        ruleSets: Int,
        warnings: Int,
        unsupportedSections: [String]
    ) {
        self.sourceBytes = sourceBytes
        self.generalKeys = generalKeys
        self.proxies = proxies
        self.groups = groups
        self.rules = rules
        self.ruleSets = ruleSets
        self.warnings = warnings
        self.unsupportedSections = unsupportedSections
    }

    public static let empty = ProfileImportSummary(
        sourceBytes: 0,
        generalKeys: 0,
        proxies: 0,
        groups: 0,
        rules: 0,
        ruleSets: 0,
        warnings: 0,
        unsupportedSections: []
    )

    public init(profile: ProxyProfile, sourceText: String) {
        self.init(
            sourceBytes: Data(sourceText.utf8).count,
            generalKeys: profile.general.count,
            proxies: profile.proxies.count,
            groups: profile.groups.count,
            rules: profile.rules.count,
            ruleSets: Set(profile.rules.filter { $0.type == "RULE-SET" }.map(\.value)).count,
            warnings: profile.warnings.count,
            unsupportedSections: profile.unsupportedSectionNames.sorted()
        )
    }

    public var sourceSizeDescription: String {
        if sourceBytes < 1024 {
            return "\(sourceBytes) B"
        }
        let kib = Double(sourceBytes) / 1024
        return String(format: "%.1f KiB", kib)
    }

    public var shortDescription: String {
        "\(sourceSizeDescription), \(proxies) proxies, \(groups) groups, \(rules) rules, \(ruleSets) rule sets, \(warnings) warnings"
    }

    public var unsupportedSectionDescription: String {
        unsupportedSections.isEmpty ? "None" : unsupportedSections.joined(separator: ", ")
    }
}
