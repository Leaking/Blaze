import Foundation

public enum ProfileSourceEditor {
    public static func addingProxy(
        name: String,
        kind: String,
        host: String,
        port: Int,
        username: String? = nil,
        password: String? = nil,
        to source: String
    ) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedPassword = password?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var fields = [normalizedKind, trimmedHost, "\(port)"]
        if normalizedKind == "trojan" {
            if !trimmedPassword.isEmpty {
                fields.append("password=\(trimmedPassword)")
            }
        } else {
            if !trimmedUsername.isEmpty {
                fields.append(trimmedUsername)
            }
            if !trimmedPassword.isEmpty {
                if trimmedUsername.isEmpty {
                    fields.append("")
                }
                fields.append(trimmedPassword)
            }
        }

        let proxyLine = "\(trimmedName) = \(fields.map(formatField).joined(separator: ", "))"
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else {
            return "[Proxy]\n\(proxyLine)\n"
        }

        var proxySectionStart: Int?
        var proxySectionEnd = lines.count

        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { continue }
            if trimmed.caseInsensitiveCompare("[Proxy]") == .orderedSame {
                proxySectionStart = index
                continue
            }
            if proxySectionStart != nil {
                proxySectionEnd = index
                break
            }
        }

        if proxySectionStart == nil {
            if lines.last?.isEmpty == false {
                lines.append("")
            }
            lines.append("[Proxy]")
            lines.append(proxyLine)
            return lines.joined(separator: "\n") + trailingNewline(from: source)
        }

        lines.insert(proxyLine, at: proxySectionEnd)
        return lines.joined(separator: "\n") + trailingNewline(from: source)
    }

    public static func removingProxy(named name: String, sourceLine: Int, from source: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !trimmedName.isEmpty, !lines.isEmpty else { return source }

        let sourceIndex = sourceLine - 1
        if lines.indices.contains(sourceIndex),
           assignmentName(from: lines[sourceIndex]) == trimmedName {
            lines.remove(at: sourceIndex)
            return lines.joined(separator: "\n")
        }

        guard let fallbackIndex = matchingProxyLineIndex(named: trimmedName, in: lines) else {
            return source
        }
        lines.remove(at: fallbackIndex)
        return lines.joined(separator: "\n")
    }

    public static func addingRule(type: String, value: String, policy: String, to source: String) -> String {
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPolicy = policy.trimmingCharacters(in: .whitespacesAndNewlines)
        let ruleLine = trimmedValue.isEmpty
            ? "\(normalizedType),\(trimmedPolicy)"
            : "\(normalizedType),\(trimmedValue),\(trimmedPolicy)"

        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else {
            return "[Rule]\n\(ruleLine)\n"
        }

        var ruleSectionStart: Int?
        var ruleSectionEnd = lines.count

        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { continue }
            if trimmed.caseInsensitiveCompare("[Rule]") == .orderedSame {
                ruleSectionStart = index
                continue
            }
            if ruleSectionStart != nil {
                ruleSectionEnd = index
                break
            }
        }

        guard let ruleSectionStart else {
            if lines.last?.isEmpty == false {
                lines.append("")
            }
            lines.append("[Rule]")
            lines.append(ruleLine)
            return lines.joined(separator: "\n") + trailingNewline(from: source)
        }

        let insertionIndex = firstFinalRuleIndex(in: lines, start: ruleSectionStart + 1, end: ruleSectionEnd) ?? ruleSectionEnd
        lines.insert(ruleLine, at: insertionIndex)
        return lines.joined(separator: "\n") + trailingNewline(from: source)
    }

    public static func removingRule(_ rule: ProxyRule, from source: String) -> String {
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return source }

        let sourceIndex = rule.sourceLine - 1
        if lines.indices.contains(sourceIndex),
           lines[sourceIndex].trimmingCharacters(in: .whitespacesAndNewlines) == rule.rawLine {
            lines.remove(at: sourceIndex)
            return lines.joined(separator: "\n")
        }

        guard let fallbackIndex = matchingRuleLineIndex(for: rule, in: lines) else {
            return source
        }
        lines.remove(at: fallbackIndex)
        return lines.joined(separator: "\n")
    }

    private static func matchingProxyLineIndex(named name: String, in lines: [String]) -> Int? {
        var isInsideProxySection = false
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                isInsideProxySection = trimmed.caseInsensitiveCompare("[Proxy]") == .orderedSame
                continue
            }
            guard isInsideProxySection, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";") else {
                continue
            }
            if assignmentName(from: lines[index]) == name {
                return index
            }
        }
        return nil
    }

    private static func matchingRuleLineIndex(for rule: ProxyRule, in lines: [String]) -> Int? {
        var isInsideRuleSection = false
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                isInsideRuleSection = trimmed.caseInsensitiveCompare("[Rule]") == .orderedSame
                continue
            }
            guard isInsideRuleSection, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";") else {
                continue
            }
            if trimmed == rule.rawLine {
                return index
            }
        }
        return nil
    }

    private static func firstFinalRuleIndex(in lines: [String], start: Int, end: Int) -> Int? {
        guard start < end else { return nil }
        for index in start..<end {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";") else { continue }
            if trimmed.uppercased().hasPrefix("FINAL,") {
                return index
            }
        }
        return nil
    }

    private static func trailingNewline(from source: String) -> String {
        source.hasSuffix("\n") ? "" : "\n"
    }

    private static func assignmentName(from line: String) -> String? {
        guard let range = line.range(of: "=") else { return nil }
        let name = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private static func quoteValue(_ value: String) -> String {
        let needsQuoting = value.contains(",")
            || value.contains("\"")
            || value.trimmingCharacters(in: .whitespacesAndNewlines) != value
        guard needsQuoting else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func formatField(_ field: String) -> String {
        guard let range = field.range(of: "=") else {
            return quoteValue(field)
        }
        let key = String(field[..<range.lowerBound])
        let value = String(field[range.upperBound...])
        return "\(key)=\(quoteValue(value))"
    }
}
