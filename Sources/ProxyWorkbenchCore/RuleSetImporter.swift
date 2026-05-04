import Foundation

public enum RuleSetImporter {
    public static func importRules(from url: URL, policy: String, sourceLineBase: Int) async throws -> [ProxyRule] {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false
        else {
            throw RuleSetImporterError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("ProxyWorkbench/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw RuleSetImporterError.httpStatus(http.statusCode)
        }

        guard data.count <= 8 * 1024 * 1024 else {
            throw RuleSetImporterError.sourceTooLarge
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw RuleSetImporterError.unsupportedEncoding
        }

        return parse(text, policy: policy, sourceLineBase: sourceLineBase)
    }

    public static func parse(_ text: String, policy: String, sourceLineBase: Int = 0) -> [ProxyRule] {
        var rules: [ProxyRule] = []
        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";") else {
                continue
            }

            let fields = ValueListParser.split(trimmed)
            guard fields.count >= 2, let rawType = fields.first, !rawType.isEmpty else {
                continue
            }

            let type = rawType.uppercased()
            if type == "FINAL" || type == "MATCH" {
                continue
            }

            rules.append(
                ProxyRule(
                    type: type,
                    value: fields[1],
                    policy: policy,
                    options: Array(fields.dropFirst(2)),
                    sourceLine: sourceLineBase + offset + 1,
                    rawLine: trimmed
                )
            )
        }
        return rules
    }
}

public enum RuleSetImporterError: Error, CustomStringConvertible, Sendable {
    case invalidURL
    case httpStatus(Int)
    case sourceTooLarge
    case unsupportedEncoding

    public var description: String {
        switch self {
        case .invalidURL:
            "Rule set URL must be http or https"
        case .httpStatus(let code):
            "Rule set server returned HTTP \(code)"
        case .sourceTooLarge:
            "Rule set source exceeds 8 MiB"
        case .unsupportedEncoding:
            "Rule set source is not UTF-8 or Latin-1 text"
        }
    }
}
