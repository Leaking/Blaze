import CFNetwork
import Foundation
@testable import ProxyWorkbenchCore
import XCTest

final class LiveTrojanProxyTests: XCTestCase {
    func testImportedTrojanProfileCanFetchThroughHTTPProxyWhenSystemDNSIsFakeIP() async throws {
        guard ProcessInfo.processInfo.environment["BLAZE_LIVE_TROJAN_TEST"] == "1" else {
            throw XCTSkip("Set BLAZE_LIVE_TROJAN_TEST=1 to run the local imported-profile connectivity test.")
        }

        guard let defaults = UserDefaults(suiteName: "com.chenhuazhao.blaze"),
              let sourceText = defaults.string(forKey: "profile.sourceText"),
              !sourceText.isEmpty else {
            XCTFail("No imported blaze profile found in com.chenhuazhao.blaze defaults.")
            return
        }

        let profile = ProfileParser.parse(sourceText)
        let selectedPolicies = defaults.dictionary(forKey: "groups.selectedPolicies") as? [String: String] ?? [:]
        let globalPolicy = defaults.string(forKey: "policy.globalProxyPolicy")
            .flatMap { profile.policyNames.contains($0) ? $0 : nil }
            ?? profile.groups.first?.name
            ?? profile.proxies.first?.name
            ?? "DIRECT"
        let routingProfile = profile.replacingRules([
            ProxyRule(type: "FINAL", value: "", policy: globalPolicy, options: [], sourceLine: -1, rawLine: "FINAL,\(globalPolicy)")
        ])

        let logStore = ProxyEventStore(limit: 500)
        let http = LocalHTTPProxyServer(logStore: logStore, routingProfile: routingProfile, groupSelections: selectedPolicies)

        try await http.start(port: 19180)

        do {
            let googleStatus = try await fetchStatus(URL(string: "https://www.google.com/generate_204")!, proxyPort: 19180)
            let baiduStatus = try await fetchStatus(URL(string: "https://www.baidu.com/")!, proxyPort: 19180)
            let notes = await notesForHTTPFetch(logStore)

            XCTAssertEqual(googleStatus, 204, notes)
            XCTAssert((200...399).contains(baiduStatus), notes)
            XCTAssert(notes.contains(" via "), notes)
            await http.stop()
        } catch {
            let notes = await notesForHTTPFetch(logStore)
            await http.stop()
            XCTFail("\(error)\n\(notes)")
        }
    }

    private func fetchStatus(_ url: URL, proxyPort: Int) async throws -> Int {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: proxyPort,
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: proxyPort
        ]

        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
        }

        var request = URLRequest(url: url)
        request.setValue("blaze-live-test", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            XCTFail("No HTTP response for \(url)")
            return 0
        }
        return httpResponse.statusCode
    }

    private func notesForHTTPFetch(_ logStore: ProxyEventStore) async -> String {
        let events = await logStore.events()
        return events
            .filter { $0.host == "www.google.com" || $0.host == "www.baidu.com" }
            .map { "\($0.status) \($0.method) \($0.host):\($0.port) \($0.note)" }
            .joined(separator: "\n")
    }
}
