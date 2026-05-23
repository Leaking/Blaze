import Foundation

public extension ProxyProfile {
    func expandedRules(ruleSetsByURL: [String: [ProxyRule]]) -> [ProxyRule] {
        var result: [ProxyRule] = []

        for rule in rules {
            if rule.type == "RULE-SET", let imported = ruleSetsByURL[rule.value] {
                result.append(contentsOf: imported)
            } else {
                result.append(rule)
            }
        }

        return result
    }

    func replacingRules(_ rules: [ProxyRule]) -> ProxyProfile {
        var copy = self
        copy.rules = rules
        return copy
    }
}
