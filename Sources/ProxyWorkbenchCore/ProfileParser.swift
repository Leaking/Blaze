import Foundation

public enum ProfileParser {
    public static func parse(_ text: String) -> ProxyProfile {
        var currentSection = ""
        var sectionLines: [String: [(line: Int, text: String)]] = [:]
        var rawSections: [String: [String]] = [:]
        var warnings: [ProfileWarning] = []

        let lines = text.components(separatedBy: .newlines)
        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";") else {
                continue
            }

            if trimmed.hasPrefix("["),
               let end = trimmed.firstIndex(of: "]") {
                currentSection = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                rawSections[currentSection, default: []] = []
                continue
            }

            guard !currentSection.isEmpty else {
                warnings.append(ProfileWarning(line: lineNumber, message: "Line outside a section was ignored."))
                continue
            }

            sectionLines[currentSection, default: []].append((lineNumber, trimmed))
            rawSections[currentSection, default: []].append(trimmed)
        }

        var general: [String: String] = [:]
        var proxies: [ProxyNode] = []
        var groups: [ProxyGroup] = []
        var rules: [ProxyRule] = []

        for (section, rows) in sectionLines {
            switch section.lowercased() {
            case "general":
                for row in rows {
                    guard let (key, value) = splitAssignment(row.text) else {
                        warnings.append(ProfileWarning(line: row.line, message: "Invalid General entry."))
                        continue
                    }
                    general[key] = value
                }
            case "proxy":
                for row in rows {
                    if let proxy = parseProxy(row.text, line: row.line) {
                        proxies.append(proxy)
                    } else {
                        warnings.append(ProfileWarning(line: row.line, message: "Invalid Proxy entry."))
                    }
                }
            case "proxy group":
                for row in rows {
                    if let group = parseGroup(row.text, line: row.line) {
                        groups.append(group)
                    } else {
                        warnings.append(ProfileWarning(line: row.line, message: "Invalid Proxy Group entry."))
                    }
                }
            case "rule":
                for row in rows {
                    if let rule = parseRule(row.text, line: row.line) {
                        rules.append(rule)
                    } else {
                        warnings.append(ProfileWarning(line: row.line, message: "Invalid Rule entry."))
                    }
                }
            default:
                warnings.append(ProfileWarning(line: rows.first?.line ?? 0, message: "Section [\(section)] is preserved but not executed."))
            }
        }

        let profile = ProxyProfile(
            general: general,
            proxies: proxies.sorted { $0.sourceLine < $1.sourceLine },
            groups: groups.sorted { $0.sourceLine < $1.sourceLine },
            rules: rules.sorted { $0.sourceLine < $1.sourceLine },
            rawSections: rawSections,
            warnings: warnings.sorted { $0.line < $1.line }
        )

        return validate(profile)
    }

    private static func validate(_ profile: ProxyProfile) -> ProxyProfile {
        var updated = profile
        let policies = profile.policyNames

        for rule in profile.rules where !rule.policy.isEmpty && !policies.contains(rule.policy) {
            updated.warnings.append(ProfileWarning(line: rule.sourceLine, message: "Rule references unknown policy '\(rule.policy)'."))
        }

        let directlyMatchedRules = RuleEngine.supportedRuleTypes
        let expandableRules = RuleEngine.externallyExpandedRuleTypes
        for rule in profile.rules {
            if expandableRules.contains(rule.type) {
                continue
            }
            if !directlyMatchedRules.contains(rule.type) {
                updated.warnings.append(ProfileWarning(line: rule.sourceLine, message: "Rule type '\(rule.type)' is parsed but not matched by the local tester or proxy."))
            }
            if rule.type == "URL-REGEX", (try? NSRegularExpression(pattern: rule.value, options: [.caseInsensitive])) == nil {
                updated.warnings.append(ProfileWarning(line: rule.sourceLine, message: "URL-REGEX pattern is invalid and will not match."))
            }
        }

        updated.groups = profile.groups.map { group in
            var filtered = group
            filtered.policies = group.policies.filter { policy in
                if isSubscriptionMetadataPolicyName(policy) {
                    updated.warnings.append(ProfileWarning(line: group.sourceLine, message: "Group '\(group.name)' ignored subscription metadata policy '\(policy)'."))
                    return false
                }
                if policies.contains(policy) {
                    return true
                }
                updated.warnings.append(ProfileWarning(line: group.sourceLine, message: "Group '\(group.name)' ignored unknown policy '\(policy)'."))
                return false
            }
            return filtered
        }

        updated.warnings.sort { lhs, rhs in
            if lhs.line == rhs.line { return lhs.message < rhs.message }
            return lhs.line < rhs.line
        }
        return updated
    }

    private static func isSubscriptionMetadataPolicyName(_ policy: String) -> Bool {
        let trimmed = policy.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.contains("traffic reset")
            || lower.contains("expire date")
            || lower.contains("days left") {
            return true
        }

        let usagePattern = #"^\d+(?:\.\d+)?\s*[kmgt]b?\s*\|\s*\d+(?:\.\d+)?"#
        return trimmed.range(of: usagePattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func parseProxy(_ line: String, line lineNumber: Int) -> ProxyNode? {
        guard let (name, value) = splitAssignment(line) else { return nil }
        let fields = ValueListParser.split(value)
        guard let rawKind = fields.first, !rawKind.isEmpty else { return nil }

        let kind = ProxyKind(profileValue: rawKind)
        let host = fields.indices.contains(1) ? fields[1] : ""
        let port = fields.indices.contains(2) ? Int(fields[2]) : nil
        var username: String?
        var password: String?
        var parameters: [String: String] = [:]

        switch kind {
        case .shadowsocks:
            if fields.indices.contains(3), !isKeyValue(fields[3]) {
                parameters["method"] = fields[3]
            }
            if fields.indices.contains(4) {
                if isKeyValue(fields[4]) {
                    collectParameter(from: fields[4], into: &parameters, username: &username, password: &password)
                } else {
                    password = fields[4]
                }
            }
            collectParameters(from: Array(fields.dropFirst(5)), into: &parameters, username: &username, password: &password)
        case .trojan:
            if fields.indices.contains(3) {
                if isKeyValue(fields[3]) {
                    collectParameter(from: fields[3], into: &parameters, username: &username, password: &password)
                } else {
                    password = fields[3]
                }
            }
            collectParameters(from: Array(fields.dropFirst(4)), into: &parameters, username: &username, password: &password)
        default:
            collectParameters(from: Array(fields.dropFirst(3)), into: &parameters, username: &username, password: &password)
        }

        return ProxyNode(
            name: name,
            kind: kind,
            rawKind: rawKind,
            host: host,
            port: port,
            username: username,
            password: password,
            parameters: parameters,
            sourceLine: lineNumber
        )
    }

    private static func parseGroup(_ line: String, line lineNumber: Int) -> ProxyGroup? {
        guard let (name, value) = splitAssignment(line) else { return nil }
        let fields = ValueListParser.split(value)
        guard let rawKind = fields.first, !rawKind.isEmpty else { return nil }

        var policies: [String] = []
        var parameters: [String: String] = [:]
        for field in fields.dropFirst() {
            if let (key, value) = splitKeyValue(field) {
                parameters[key] = value
            } else if !field.isEmpty {
                policies.append(field)
            }
        }

        return ProxyGroup(
            name: name,
            kind: ProxyGroupKind(profileValue: rawKind),
            rawKind: rawKind,
            policies: policies,
            parameters: parameters,
            sourceLine: lineNumber
        )
    }

    private static func parseRule(_ line: String, line lineNumber: Int) -> ProxyRule? {
        let fields = ValueListParser.split(line)
        guard let rawType = fields.first, !rawType.isEmpty else { return nil }
        let type = rawType.uppercased()

        if type == "FINAL" || type == "MATCH" {
            return ProxyRule(
                type: type,
                value: "",
                policy: fields.indices.contains(1) ? fields[1] : "DIRECT",
                options: Array(fields.dropFirst(2)),
                sourceLine: lineNumber,
                rawLine: line
            )
        }

        guard fields.count >= 3 else { return nil }
        return ProxyRule(
            type: type,
            value: fields[1],
            policy: fields[2],
            options: Array(fields.dropFirst(3)),
            sourceLine: lineNumber,
            rawLine: line
        )
    }

    private static func splitAssignment(_ line: String) -> (String, String)? {
        guard let range = line.range(of: "=") else { return nil }
        let key = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private static func splitKeyValue(_ field: String) -> (String, String)? {
        guard let range = field.range(of: "=") else { return nil }
        let key = String(field[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(field[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private static func isKeyValue(_ field: String) -> Bool {
        splitKeyValue(field) != nil
    }

    private static func collectParameters(
        from fields: [String],
        into parameters: inout [String: String],
        username: inout String?,
        password: inout String?
    ) {
        var positionalIndex = 0
        for field in fields where !field.isEmpty {
            if isKeyValue(field) {
                collectParameter(from: field, into: &parameters, username: &username, password: &password)
                continue
            }

            if username == nil {
                username = field
            } else if password == nil {
                password = field
            } else {
                positionalIndex += 1
                parameters["arg\(positionalIndex)"] = field
            }
        }
    }

    private static func collectParameter(
        from field: String,
        into parameters: inout [String: String],
        username: inout String?,
        password: inout String?
    ) {
        guard let (key, value) = splitKeyValue(field) else { return }
        switch key.lowercased() {
        case "username", "user":
            username = value
        case "password", "passwd", "pass":
            password = value
        default:
            parameters[key] = value
        }
    }
}

public enum ValueListParser {
    public static func split(_ value: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false

        for character in value {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }

            if character == "\\" {
                escaped = true
                continue
            }

            if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                } else {
                    current.append(character)
                }
                continue
            }

            if character == ",", quote == nil {
                result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(character)
            }
        }

        result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return result
    }
}
