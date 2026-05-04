import Foundation

public enum PolicyResolutionAction: Hashable, Sendable {
    case direct
    case reject
    case proxy(kind: ProxyKind, name: String, endpoint: String)
    case unsupported(String)

    public var displayValue: String {
        switch self {
        case .direct:
            "DIRECT"
        case .reject:
            "REJECT"
        case .proxy(let kind, let name, let endpoint):
            "\(name) (\(kind.displayName), \(endpoint))"
        case .unsupported(let reason):
            "Unsupported: \(reason)"
        }
    }
}

public struct PolicyResolutionResult: Hashable, Sendable {
    public var action: PolicyResolutionAction
    public var path: [String]

    public init(action: PolicyResolutionAction, path: [String]) {
        self.action = action
        self.path = path
    }

    public var pathDescription: String {
        path.joined(separator: " -> ")
    }
}

public enum PolicyResolver {
    public static func resolve(policy: String, in profile: ProxyProfile, groupSelections: [String: String] = [:]) -> PolicyResolutionResult {
        resolve(policy: policy, in: profile, groupSelections: groupSelections, visited: [])
    }

    private static func resolve(policy: String, in profile: ProxyProfile, groupSelections: [String: String], visited: Set<String>) -> PolicyResolutionResult {
        let normalized = policy.uppercased()
        if normalized.hasPrefix("REJECT") {
            return PolicyResolutionResult(action: .reject, path: [policy])
        }

        if normalized == "DIRECT" {
            return PolicyResolutionResult(action: .direct, path: [policy])
        }

        guard !visited.contains(policy) else {
            return PolicyResolutionResult(action: .unsupported("Cycle detected"), path: [policy, "cycle"])
        }

        if let group = profile.groups.first(where: { $0.name == policy }) {
            let selected = groupSelections[policy].flatMap { group.policies.contains($0) ? $0 : nil } ?? group.policies.first
            guard let selected else {
                return PolicyResolutionResult(action: .unsupported("Empty group"), path: [policy, "empty group"])
            }

            let next = resolve(policy: selected, in: profile, groupSelections: groupSelections, visited: visited.union([policy]))
            return PolicyResolutionResult(action: next.action, path: [policy] + next.path)
        }

        if let node = profile.proxies.first(where: { $0.name == policy }) {
            switch node.kind {
            case .direct:
                return PolicyResolutionResult(action: .direct, path: [policy])
            case .reject:
                return PolicyResolutionResult(action: .reject, path: [policy])
            case .http, .socks5, .trojan:
                return PolicyResolutionResult(action: .proxy(kind: node.kind, name: node.name, endpoint: node.endpoint), path: [policy])
            default:
                return PolicyResolutionResult(action: .unsupported("\(node.kind.displayName) upstream unsupported"), path: [policy, "\(node.kind.displayName) upstream unsupported"])
            }
        }

        return PolicyResolutionResult(action: .unsupported("Unknown policy"), path: [policy, "unknown policy"])
    }
}
