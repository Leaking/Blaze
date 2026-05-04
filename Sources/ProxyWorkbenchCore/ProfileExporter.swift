import Foundation

public enum ProfileExporter {
    public static func sanitizedJSON(from profile: ProxyProfile) -> String {
        let proxies = profile.proxies.map { proxy in
            [
                "name": proxy.name,
                "type": proxy.rawKind,
                "host": proxy.host,
                "port": proxy.port.map(String.init) ?? "",
                "username": proxy.redactedUsername,
                "password": proxy.password == nil ? "" : "********",
                "parameters": proxy.redactedParameters
            ] as [String: Any]
        }

        let groups = profile.groups.map { group in
            [
                "name": group.name,
                "type": group.rawKind,
                "policies": group.policies,
                "parameters": group.parameters
            ] as [String: Any]
        }

        let rules = profile.rules.map { rule in
            [
                "type": rule.type,
                "value": rule.value,
                "policy": rule.policy,
                "options": rule.options
            ] as [String: Any]
        }

        let payload: [String: Any] = [
            "general": profile.general.redactingSensitiveValues(),
            "proxies": proxies,
            "groups": groups,
            "rules": rules,
            "unsupported_sections": profile.unsupportedSectionNames,
            "warnings": profile.warnings.map { ["line": $0.line, "message": $0.message] }
        ]

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

private extension Dictionary where Key == String, Value == String {
    func redactingSensitiveValues() -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in self {
            result[key] = ProxyNode.isSensitive(key) && !value.isEmpty ? "********" : value
        }
        return result
    }
}
