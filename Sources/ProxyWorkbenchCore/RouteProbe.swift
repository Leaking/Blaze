import Foundation

public struct RouteProbeResult: Hashable, Sendable {
    public var source: String
    public var normalizedInput: String
    public var policy: String
    public var rule: String
    public var reason: String
    public var policyPath: String
    public var outbound: String

    public init(source: String, normalizedInput: String, policy: String, rule: String, reason: String, policyPath: String = "", outbound: String = "") {
        self.source = source
        self.normalizedInput = normalizedInput
        self.policy = policy
        self.rule = rule
        self.reason = reason
        self.policyPath = policyPath
        self.outbound = outbound
    }
}

public struct RouteProbe: Sendable {
    private var profile: ProxyProfile
    private var ruleSetsByURL: [String: [ProxyRule]]
    private var groupSelections: [String: String]

    public init(profile: ProxyProfile, ruleSetsByURL: [String: [ProxyRule]] = [:], groupSelections: [String: String] = [:]) {
        self.profile = profile
        self.ruleSetsByURL = ruleSetsByURL
        self.groupSelections = groupSelections
    }

    public func evaluate(_ input: String) -> RouteProbeResult {
        let expandedProfile = profile.replacingRules(profile.expandedRules(ruleSetsByURL: ruleSetsByURL))

        if let bypass = GeneralBypassMatcher(profile: expandedProfile).firstMatch(for: input) {
            return RouteProbeResult(
                source: "General",
                normalizedInput: input.trimmingCharacters(in: .whitespacesAndNewlines),
                policy: "DIRECT",
                rule: "\(bypass.sourceKey) = \(bypass.entry)",
                reason: bypass.reason,
                policyPath: "DIRECT",
                outbound: "DIRECT"
            )
        }

        if let match = RuleEngine(rules: expandedProfile.rules).firstMatch(for: input) {
            let resolution = PolicyResolver.resolve(policy: match.rule.policy, in: expandedProfile, groupSelections: groupSelections)
            return RouteProbeResult(
                source: "Rule",
                normalizedInput: match.normalizedInput,
                policy: match.rule.policy,
                rule: match.rule.displayCondition,
                reason: match.reason,
                policyPath: resolution.pathDescription,
                outbound: resolution.action.displayValue
            )
        }

        return RouteProbeResult(
            source: "Default",
            normalizedInput: input.trimmingCharacters(in: .whitespacesAndNewlines),
            policy: "DIRECT",
            rule: "No rule matched",
            reason: "Default direct",
            policyPath: "DIRECT",
            outbound: "DIRECT"
        )
    }
}
