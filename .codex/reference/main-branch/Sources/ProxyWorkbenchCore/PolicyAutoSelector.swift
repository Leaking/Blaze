import Foundation

public enum PolicyAutoSelector {
    public static func selections(
        profile: ProxyProfile,
        current: [String: String],
        latencyResults: [String: LatencyResult]
    ) -> [String: String] {
        var next = current
        for group in profile.groups where group.kind.isAutoSelectable {
            if let policy = bestPolicy(for: group, profile: profile, latencyResults: latencyResults) {
                next[group.name] = policy
            }
        }
        return next
    }

    public static func bestPolicy(
        for group: ProxyGroup,
        profile: ProxyProfile,
        latencyResults: [String: LatencyResult]
    ) -> String? {
        let proxyNames = Set(profile.proxies.map(\.name))
        let candidates = group.policies.compactMap { policy -> (String, Int)? in
            guard proxyNames.contains(policy),
                  let result = latencyResults[policy],
                  result.status == "Reachable",
                  let milliseconds = result.milliseconds
            else {
                return nil
            }
            return (policy, milliseconds)
        }

        return candidates.min {
            if $0.1 == $1.1 { return $0.0 < $1.0 }
            return $0.1 < $1.1
        }?.0
    }
}

public extension ProxyGroupKind {
    var isAutoSelectable: Bool {
        switch self {
        case .urlTest, .fallback, .loadBalance, .smart:
            true
        default:
            false
        }
    }
}
