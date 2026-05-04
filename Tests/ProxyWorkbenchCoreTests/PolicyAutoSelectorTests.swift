import XCTest
@testable import ProxyWorkbenchCore

final class PolicyAutoSelectorTests: XCTestCase {
    func testBestPolicyChoosesLowestReachableLatencyInAutoGroup() {
        let profile = ProxyProfile(
            proxies: [
                ProxyNode(name: "Slow", kind: .http, rawKind: "http", host: "127.0.0.1", port: 8080, username: nil, password: nil, parameters: [:], sourceLine: 1),
                ProxyNode(name: "Fast", kind: .http, rawKind: "http", host: "127.0.0.1", port: 8081, username: nil, password: nil, parameters: [:], sourceLine: 2),
                ProxyNode(name: "Down", kind: .http, rawKind: "http", host: "127.0.0.1", port: 8082, username: nil, password: nil, parameters: [:], sourceLine: 3)
            ],
            groups: [
                ProxyGroup(name: "Auto", kind: .urlTest, rawKind: "url-test", policies: ["Slow", "Fast", "Down", "DIRECT"], parameters: [:], sourceLine: 4)
            ]
        )
        let results = [
            "Slow": LatencyResult(proxyName: "Slow", milliseconds: 120, status: "Reachable", message: "ok"),
            "Fast": LatencyResult(proxyName: "Fast", milliseconds: 20, status: "Reachable", message: "ok"),
            "Down": LatencyResult(proxyName: "Down", milliseconds: nil, status: "Failed", message: "no")
        ]

        XCTAssertEqual(PolicyAutoSelector.bestPolicy(for: profile.groups[0], profile: profile, latencyResults: results), "Fast")
    }

    func testSelectionsOnlyMutateAutoSelectableGroups() {
        let profile = ProxyProfile(
            proxies: [
                ProxyNode(name: "A", kind: .http, rawKind: "http", host: "127.0.0.1", port: 8080, username: nil, password: nil, parameters: [:], sourceLine: 1),
                ProxyNode(name: "B", kind: .http, rawKind: "http", host: "127.0.0.1", port: 8081, username: nil, password: nil, parameters: [:], sourceLine: 2)
            ],
            groups: [
                ProxyGroup(name: "Auto", kind: .fallback, rawKind: "fallback", policies: ["A", "B"], parameters: [:], sourceLine: 3),
                ProxyGroup(name: "Manual", kind: .select, rawKind: "select", policies: ["A", "B"], parameters: [:], sourceLine: 4)
            ]
        )
        let current = ["Auto": "A", "Manual": "A"]
        let results = [
            "A": LatencyResult(proxyName: "A", milliseconds: 90, status: "Reachable", message: "ok"),
            "B": LatencyResult(proxyName: "B", milliseconds: 30, status: "Reachable", message: "ok")
        ]

        let selected = PolicyAutoSelector.selections(profile: profile, current: current, latencyResults: results)

        XCTAssertEqual(selected["Auto"], "B")
        XCTAssertEqual(selected["Manual"], "A")
    }
}
