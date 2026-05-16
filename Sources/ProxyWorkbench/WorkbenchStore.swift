import AppKit
import CFNetwork
import Darwin
import Foundation
import ProxyWorkbenchCore

enum ProxyRoutingMode: String, CaseIterable, Identifiable {
    case direct
    case global
    case ruleBased

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: "Direct Outbound"
        case .global: "Global Proxy"
        case .ruleBased: "Rule-based Proxy"
        }
    }

    var subtitle: String {
        switch self {
        case .direct: "All requests are routed directly, while local skip-proxy bypasses still apply."
        case .global: "All requests are routed through the selected global outbound."
        case .ruleBased: "Using rule system to determine how to process requests."
        }
    }
}

enum ConnectivityTestStatus: String, Hashable, Sendable {
    case passed = "Passed"
    case failed = "Failed"
    case info = "Info"
}

struct ConnectivityTestResult: Identifiable, Hashable, Sendable {
    let id = UUID()
    var date = Date()
    var name: String
    var transport: String
    var target: String
    var status: ConnectivityTestStatus
    var detail: String
    var durationMilliseconds: Int?

    var durationText: String {
        durationMilliseconds.map { "\($0) ms" } ?? "-"
    }
}

@MainActor
final class WorkbenchStore: ObservableObject {
    @Published private(set) var profile: ProxyProfile = .empty
    @Published var sourceText: String = ""
    @Published var remoteProfileURLText: String = ""
    @Published var ruleProbeText: String = "www.apple.com"
    @Published var networkServiceName: String = "Wi-Fi"
    @Published private(set) var routeProbeResult: RouteProbeResult?
    @Published private(set) var profileSummary: ProfileImportSummary = .empty
    @Published private(set) var latencyResults: [String: LatencyResult] = [:]
    @Published private(set) var statusText: String = "Ready"
    @Published private(set) var sanitizedExport: String = "{}"
    @Published var revealSecrets = false
    @Published var proxyListenPort = 19080
    @Published var socksListenPort = 19081
    @Published private(set) var selectedPolicies: [String: String] = [:]
    @Published private(set) var ruleSetRulesByURL: [String: [ProxyRule]] = [:]
    @Published private(set) var ruleSetStatusByURL: [String: String] = [:]
    @Published private(set) var ruleSetImportInProgress = false
    @Published private(set) var remoteImportInProgress = false
    @Published private(set) var remotePreviewInProgress = false
    @Published private(set) var remotePreview: RemoteProfilePreview?
    @Published private(set) var detectedNetworkServices: [String] = []
    @Published private(set) var networkServiceDetectionInProgress = false
    @Published private(set) var systemProxyStatusInProgress = false
    @Published private(set) var systemProxyStatus: MacSystemProxyStatus = .unknown(expectedHTTPPort: 19080, expectedSOCKSPort: 19081)
    @Published private(set) var effectiveProxyStatus: MacEffectiveProxyStatus = .unknown(expectedHTTPPort: 19080, expectedSOCKSPort: 19081)
    @Published private(set) var systemProxyApplyInProgress = false
    @Published private(set) var systemProxyRestorePoint: MacSystemProxyStatus?
    @Published private(set) var proxyRoutingMode: ProxyRoutingMode = .ruleBased
    @Published private(set) var globalProxyPolicy: String = ""
    @Published private(set) var proxyServerRunning = false
    @Published private(set) var socksServerRunning = false
    @Published private(set) var proxyEvents: [ProxyServerEvent] = []
    @Published private(set) var proxyPolicyStats: [ProxyPolicyHitStat] = []
    @Published private(set) var proxyRuleStats: [ProxyRuleHitStat] = []
    @Published private(set) var favoriteProxyNames: Set<String> = []
    @Published private(set) var connectivityTestRunning = false
    @Published private(set) var connectivityTestResults: [ConnectivityTestResult] = []
    @Published private(set) var packetTunnelStatusText = "System extension not installed"
    @Published private(set) var packetTunnelConnected = false
    @Published private(set) var packetTunnelTransitioning = false
    @Published private(set) var packetTunnelHostEntitlementText = SystemExtensionController.hostEntitlementStatusText
    @Published private(set) var packetTunnelExcludedIPv4Summary = "Not computed"

    private let probe = LatencyProbe()
    private let systemExtensionController = SystemExtensionController()
    private var proxyLogStore = ProxyEventStore(diskLogURL: ProxyEventStore.defaultDiskLogURL())
    private var proxyServer: LocalHTTPProxyServer?
    private var socksServer: LocalSOCKS5ProxyServer?
    private var proxyRefreshTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private var didLoadInitialProfile = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        systemExtensionController.statusHandler = { [weak self] message in
            self?.packetTunnelStatusText = message
            self?.statusText = message
        }
    }

    var localProxySummary: String {
        if !proxyServerRunning && !socksServerRunning {
            return "Stopped"
        }
        let http = proxyServerRunning ? "\(proxyListenPort)" : "off"
        let socks = socksServerRunning ? "\(socksListenPort)" : "off"
        return "HTTP \(http) / SOCKS5 \(socks)"
    }

    var localProxyRunning: Bool {
        proxyServerRunning || socksServerRunning
    }

    var effectiveSystemProxySummary: String {
        effectiveProxyStatus.summary
    }

    var effectiveSystemProxyIsBlaze: Bool {
        effectiveProxyStatus.matchesBlaze
    }

    var browserTrafficShouldReachBlaze: Bool {
        effectiveProxyStatus.matchesBlaze || packetTunnelConnected
    }

    var systemProxyRestoreSummary: String {
        systemProxyRestorePoint?.summary ?? "None"
    }

    var availableGlobalPolicies: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in profile.groups.map(\.name) + profile.proxies.map(\.name) + ["DIRECT"] {
            guard !name.isEmpty, !seen.contains(name) else { continue }
            seen.insert(name)
            result.append(name)
        }
        return result
    }

    var activeRoutingSummary: String {
        switch proxyRoutingMode {
        case .direct:
            return "Direct Outbound"
        case .global:
            return "Global Proxy via \(resolvedGlobalProxyPolicy)"
        case .ruleBased:
            return "Rule-based Proxy"
        }
    }

    var activeProfileName: String {
        if !globalProxyPolicy.isEmpty && availableGlobalPolicies.contains(globalProxyPolicy) {
            return globalProxyPolicy
        }
        if let firstGroup = profile.groups.first {
            return firstGroup.name
        }
        if let firstProxy = profile.proxies.first {
            return firstProxy.name
        }
        return "No Profile"
    }

    private var resolvedGlobalProxyPolicy: String {
        if availableGlobalPolicies.contains(globalProxyPolicy) {
            return globalProxyPolicy
        }
        if availableGlobalPolicies.contains("Proxies") {
            return "Proxies"
        }
        return availableGlobalPolicies.first ?? "DIRECT"
    }

    func loadInitialProfile() {
        guard !didLoadInitialProfile else { return }
        didLoadInitialProfile = true

        remoteProfileURLText = defaults.string(forKey: PersistenceKey.remoteProfileURL) ?? ""
        let savedHTTPPort = defaults.integer(forKey: PersistenceKey.httpPort)
        if (1...65535).contains(savedHTTPPort) {
            proxyListenPort = savedHTTPPort
        }
        let savedSOCKSPort = defaults.integer(forKey: PersistenceKey.socksPort)
        if (1...65535).contains(savedSOCKSPort) {
            socksListenPort = savedSOCKSPort
        }
        systemProxyStatus = .unknown(expectedHTTPPort: proxyListenPort, expectedSOCKSPort: socksListenPort)
        if let savedSelections = defaults.dictionary(forKey: PersistenceKey.selectedPolicies) as? [String: String] {
            selectedPolicies = savedSelections
        }
        if let savedService = defaults.string(forKey: PersistenceKey.networkServiceName), !savedService.isEmpty {
            networkServiceName = savedService
        }
        if let savedMode = defaults.string(forKey: PersistenceKey.proxyRoutingMode),
           let mode = ProxyRoutingMode(rawValue: savedMode) {
            proxyRoutingMode = mode
        }
        globalProxyPolicy = defaults.string(forKey: PersistenceKey.globalProxyPolicy) ?? ""
        favoriteProxyNames = Set(defaults.stringArray(forKey: PersistenceKey.favoriteProxyNames) ?? [])
        restoreSavedSystemProxyRestorePoint()

        if let savedSource = defaults.string(forKey: PersistenceKey.sourceText), !savedSource.isEmpty {
            sourceText = savedSource
            parseSource(persist: false)
            restoreRuleSetCache()
            statusText = "Restored saved profile"
        } else {
            profile = .empty
            profileSummary = .empty
            sanitizedExport = ProfileExporter.sanitizedJSON(from: profile)
            statusText = "Paste a profile URL or import a local profile to begin"
        }

        let hasSavedNetworkService = (defaults.string(forKey: PersistenceKey.networkServiceName)?.isEmpty == false)

        Task {
            if !hasSavedNetworkService {
                await detectAndAdoptDefaultNetworkService()
            }
            await refreshSystemProxyStatus()
            await refreshPacketTunnelStatus(updateStatusText: false)
            if systemProxyStatus.activation == .active {
                await startLocalProxyStack()
            }
            if !profile.rules.filter({ $0.type == "RULE-SET" }).isEmpty, importedRuleSetRuleCount == 0 {
                await importRuleSets()
            }
        }
    }

    private func detectAndAdoptDefaultNetworkService() async {
        do {
            let output = try await Self.networkServiceListOutput()
            let services = MacNetworkServiceList.parse(output)
            detectedNetworkServices = services
            if !services.isEmpty, !services.contains(networkServiceName), let first = services.first {
                networkServiceName = first
                defaults.set(first, forKey: PersistenceKey.networkServiceName)
            }
        } catch {
            // Detection is best-effort; the user can still set it manually.
        }
    }

    func loadSample(persist: Bool = true) {
        sourceText = SampleProfiles.starter
        parseSource(persist: persist)
        statusText = "Loaded sample profile"
    }

    func parseSource(persist: Bool = true) {
        profile = ProfileParser.parse(sourceText)
        reconcileSelectedPolicies()
        reconcileGlobalProxyPolicy()
        reconcileRuleSets()
        profileSummary = ProfileImportSummary(profile: profile, sourceText: sourceText)
        sanitizedExport = ProfileExporter.sanitizedJSON(from: profile)
        runRuleProbe()
        if persist {
            saveLocalState()
        }
        statusText = "Parsed \(profileSummary.shortDescription)"
    }

    func importFile(url: URL) {
        do {
            let data = try Data(contentsOf: url)
            sourceText = try ProfileSourceDecoder.decodedText(from: data)
            parseSource()
            statusText = "Imported \(url.lastPathComponent)"
        } catch {
            statusText = "Import failed: \(error)"
        }
    }

    func addProxy(name: String, kind: String, host: String, portText: String, username: String, password: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            statusText = "Proxy add failed: enter a name"
            return
        }
        guard !trimmedName.contains("="), !trimmedName.contains("\n") else {
            statusText = "Proxy add failed: name cannot contain '=' or line breaks"
            return
        }
        guard !profile.policyNames.contains(trimmedName) else {
            statusText = "Proxy add failed: name already exists"
            return
        }

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            statusText = "Proxy add failed: enter a host"
            return
        }

        guard let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65535).contains(port) else {
            statusText = "Proxy add failed: enter a valid port"
            return
        }

        let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let supportedKinds = ["http", "https", "socks5", "trojan"]
        guard supportedKinds.contains(normalizedKind) else {
            statusText = "Proxy add failed: unsupported protocol"
            return
        }

        sourceText = ProfileSourceEditor.addingProxy(
            name: trimmedName,
            kind: normalizedKind,
            host: trimmedHost,
            port: port,
            username: username,
            password: password,
            to: sourceText
        )
        parseSource()
        statusText = "Added proxy \(trimmedName)"
    }

    func addRule(type: String, value: String, policy: String) {
        let trimmedPolicy = policy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPolicy.isEmpty else {
            statusText = "Rule add failed: choose a policy"
            return
        }

        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if normalizedType != "FINAL", value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statusText = "Rule add failed: enter a value"
            return
        }

        sourceText = ProfileSourceEditor.addingRule(type: normalizedType, value: value, policy: trimmedPolicy, to: sourceText)
        parseSource()
        statusText = "Added \(normalizedType) rule for \(trimmedPolicy)"
    }

    func removeRule(_ rule: ProxyRule) {
        let edited = ProfileSourceEditor.removingRule(rule, from: sourceText)
        guard edited != sourceText else {
            statusText = "Rule remove failed: source line not found"
            return
        }

        sourceText = edited
        parseSource()
        statusText = "Removed \(rule.type) rule"
    }

    func importRemoteProfile() async {
        let trimmed = remoteProfileURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            statusText = "Remote import failed: enter an http or https URL"
            return
        }

        remoteImportInProgress = true
        statusText = "Downloading remote profile..."
        defer { remoteImportInProgress = false }

        do {
            sourceText = try await RemoteProfileImporter.importText(from: url)
            parseSource()
            saveLocalState()
            statusText = "Imported remote profile: \(profileSummary.shortDescription)"
        } catch {
            statusText = "Remote import failed: \(error)"
        }
    }

    func importRemoteProfileAndRuleSets() async {
        let trimmed = remoteProfileURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            statusText = "Remote import failed: enter an http or https URL"
            return
        }

        remoteImportInProgress = true
        statusText = "Downloading remote profile..."
        defer { remoteImportInProgress = false }

        do {
            sourceText = try await RemoteProfileImporter.importText(from: url)
            parseSource()
            saveLocalState()
            let importedRules = await importRuleSetsForCurrentProfile()
            statusText = importedRules > 0
                ? "Imported profile and \(importedRules) rule-set rules: \(profileSummary.shortDescription)"
                : "Imported remote profile: \(profileSummary.shortDescription)"
        } catch {
            statusText = "Remote import failed: \(error)"
        }
    }

    func previewRemoteProfile() async {
        let trimmed = remoteProfileURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            statusText = "Remote preview failed: enter an http or https URL"
            return
        }

        remotePreviewInProgress = true
        statusText = "Previewing remote profile..."
        defer { remotePreviewInProgress = false }

        do {
            remotePreview = try await RemoteProfilePreviewer.preview(from: url)
            statusText = "Previewed remote profile: \(remotePreview?.summary.shortDescription ?? "")"
        } catch {
            statusText = "Remote preview failed: \(error)"
        }
    }

    func runRuleProbe() {
        routeProbeResult = RouteProbe(profile: profile, ruleSetsByURL: ruleSetRulesByURL, groupSelections: selectedPolicies).evaluate(ruleProbeText)
    }

    func selectedPolicy(for group: ProxyGroup) -> String {
        selectedPolicies[group.name].flatMap { group.policies.contains($0) ? $0 : nil } ?? group.policies.first ?? ""
    }

    func setSelectedPolicy(_ policy: String, for group: ProxyGroup) {
        guard group.policies.contains(policy) else { return }
        selectedPolicies[group.name] = policy
        saveLocalState()
        statusText = proxyServerRunning ? "Selected \(policy) for \(group.name); restart proxy to apply" : "Selected \(policy) for \(group.name)"
    }

    func setProxyRoutingMode(_ mode: ProxyRoutingMode) {
        guard proxyRoutingMode != mode else { return }
        proxyRoutingMode = mode
        reconcileGlobalProxyPolicy()
        saveLocalState()
        let suffix = localProxyRunning ? "; restart listeners to apply" : ""
        statusText = "Policy mode: \(mode.title)\(suffix)"
    }

    func setGlobalProxyPolicy(_ policy: String) {
        guard availableGlobalPolicies.contains(policy) else { return }
        globalProxyPolicy = policy
        saveLocalState()
        let suffix = proxyRoutingMode == .global && localProxyRunning ? "; restart listeners to apply" : ""
        statusText = "Global proxy: \(policy)\(suffix)"
    }

    func toggleFavoriteProxy(_ name: String) {
        if favoriteProxyNames.contains(name) {
            favoriteProxyNames.remove(name)
            statusText = "Removed \(name) from favorites"
        } else {
            favoriteProxyNames.insert(name)
            statusText = "Favorited \(name)"
        }
        saveLocalState()
    }

    func bestLatencyPolicy(for group: ProxyGroup) -> String? {
        PolicyAutoSelector.bestPolicy(for: group, profile: profile, latencyResults: latencyResults)
    }

    func applyBestLatencySelections() {
        guard !latencyResults.isEmpty else {
            statusText = "Run Probe Endpoints before applying best latency selections"
            return
        }

        let next = PolicyAutoSelector.selections(profile: profile, current: selectedPolicies, latencyResults: latencyResults)
        let changed = next.filter { selectedPolicies[$0.key] != $0.value }
        selectedPolicies = next
        saveLocalState()

        if changed.isEmpty {
            statusText = "No auto-selectable group had a reachable measured policy"
        } else {
            let suffix = proxyServerRunning || socksServerRunning ? "; restart listeners to apply" : ""
            statusText = "Applied best latency to \(changed.count) groups\(suffix)"
        }
    }

    var expandedRuleCount: Int {
        profile.expandedRules(ruleSetsByURL: ruleSetRulesByURL).count
    }

    var importedRuleSetRuleCount: Int {
        ruleSetRulesByURL.values.reduce(0) { $0 + $1.count }
    }

    func importRuleSets() async {
        let ruleSetRules = profile.rules.filter { $0.type == "RULE-SET" }
        guard !ruleSetRules.isEmpty else {
            statusText = "No RULE-SET entries to import"
            return
        }

        ruleSetImportInProgress = true
        statusText = "Downloading \(ruleSetRules.count) rule sets..."
        defer { ruleSetImportInProgress = false }

        _ = await importRuleSetsForCurrentProfile()
        statusText = "Imported \(importedRuleSetRuleCount) rule-set rules"
    }

    private func importRuleSetsForCurrentProfile() async -> Int {
        let ruleSetRules = profile.rules.filter { $0.type == "RULE-SET" }
        guard !ruleSetRules.isEmpty else {
            return 0
        }

        var imported = ruleSetRulesByURL
        var statuses = ruleSetStatusByURL

        for rule in ruleSetRules {
            guard let url = URL(string: rule.value) else {
                statuses[rule.value] = "Invalid URL"
                continue
            }

            do {
                let rules = try await RuleSetImporter.importRules(from: url, policy: rule.policy, sourceLineBase: rule.sourceLine * 10_000)
                imported[rule.value] = rules
                statuses[rule.value] = "Imported \(rules.count)"
            } catch {
                statuses[rule.value] = "Failed: \(error)"
            }
        }

        ruleSetRulesByURL = imported
        ruleSetStatusByURL = statuses
        persistRuleSetCache()
        runRuleProbe()
        return importedRuleSetRuleCount
    }

    func copyExportToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sanitizedExport, forType: .string)
        statusText = "Copied sanitized export"
    }

    func copyNetworkServiceListCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MacProxySetupCommands.listNetworkServicesCommand, forType: .string)
        statusText = "Copied network service list command"
    }

    func detectNetworkServices() async {
        networkServiceDetectionInProgress = true
        statusText = "Detecting network services..."
        defer { networkServiceDetectionInProgress = false }

        do {
            let output = try await Self.networkServiceListOutput()
            let services = MacNetworkServiceList.parse(output)
            detectedNetworkServices = services
            if let first = services.first, !services.contains(networkServiceName) {
                networkServiceName = first
            }
            saveLocalState()
            statusText = services.isEmpty ? "No network services detected" : "Detected \(services.count) network services"
        } catch {
            statusText = "Network service detection failed: \(error)"
        }
    }

    func copyEnableSystemProxyCommands() {
        saveLocalState()
        let commands = MacProxySetupCommands(networkService: networkServiceName, httpPort: proxyListenPort, socksPort: socksListenPort)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commands.enableCommands, forType: .string)
        statusText = "Copied macOS proxy enable commands"
    }

    func copyDisableSystemProxyCommands() {
        saveLocalState()
        let commands = MacProxySetupCommands(networkService: networkServiceName, httpPort: proxyListenPort, socksPort: socksListenPort)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commands.disableCommands, forType: .string)
        statusText = "Copied macOS proxy disable commands"
    }

    func openBlazeTestBrowser() async {
        await startLocalProxyStack()
        guard proxyServerRunning && socksServerRunning else {
            statusText = "Test browser failed: local HTTP/SOCKS5 listeners are not running"
            return
        }

        do {
            try await Self.openChromeTestBrowser(httpPort: proxyListenPort, socksPort: socksListenPort)
            statusText = "Opened Chrome test profile through blaze HTTP \(proxyListenPort), SOCKS5 \(socksListenPort)"
        } catch {
            statusText = "Test browser failed: \(error)"
        }
    }

    func applySystemProxySettings() async {
        await captureSystemProxyRestorePointIfNeeded()
        let applied = await runSystemProxyCommands(
            commands: MacProxySetupCommands(networkService: networkServiceName, httpPort: proxyListenPort, socksPort: socksListenPort).enableInvocations,
            successStatus: "Applied macOS proxy settings for \(networkServiceName)"
        )
        if applied {
            await flushSystemNameCaches()
            await refreshSystemProxyStatus(updateStatusText: false)
            statusText = effectiveProxyStatus.matchesBlaze
                ? "Applied blaze as effective macOS proxy"
                : "Applied \(networkServiceName), but effective proxy is \(effectiveProxyStatus.summary)"
        }
    }

    func disableSystemProxySettings() async {
        await runSystemProxyCommands(
            commands: MacProxySetupCommands(networkService: networkServiceName, httpPort: proxyListenPort, socksPort: socksListenPort).disableInvocations,
            successStatus: "Disabled macOS proxy settings for \(networkServiceName)"
        )
    }

    func startLocalProxyStack() async {
        if !proxyServerRunning {
            await startLocalProxyServer()
        }
        if !socksServerRunning {
            await startLocalSocksServer()
        }
        if proxyServerRunning && socksServerRunning {
            statusText = "Local proxy listening on HTTP \(proxyListenPort) and SOCKS5 \(socksListenPort)"
        }
    }

    func stopLocalProxyStack() async {
        if proxyServerRunning {
            await stopLocalProxyServer()
        }
        if socksServerRunning {
            await stopLocalSocksServer()
        }
        statusText = "Local proxy stopped"
    }

    func startAndApplySystemProxy() async {
        await startLocalProxyStack()
        guard proxyServerRunning || socksServerRunning else { return }
        await applySystemProxySettings()
    }

    func disableSystemProxyAndStop() async {
        await refreshSystemProxyStatus()
        switch systemProxyStatus.activation {
        case .active, .partial:
            if await restorePreviousSystemProxySettings() {
                break
            }
            await disableSystemProxySettings()
        case .inactive:
            statusText = "System proxy points elsewhere; leaving it unchanged"
        case .unknown:
            statusText = "System proxy status unknown; leaving it unchanged"
        }
        await stopLocalProxyStack()
    }

    func activatePacketTunnelSystemExtension() {
        systemExtensionController.activate()
    }

    func deactivatePacketTunnelSystemExtension() {
        systemExtensionController.deactivate()
    }

    func installPacketTunnelConfiguration() async {
        do {
            let excludedIPv4Addresses = await packetTunnelExcludedIPv4Addresses()
            try await PacketTunnelConfigurationManager.installOrUpdateConfiguration(
                httpPort: proxyListenPort,
                socksPort: socksListenPort,
                excludedIPv4Addresses: excludedIPv4Addresses
            )
            await refreshPacketTunnelStatus(updateStatusText: false)
            let status = packetTunnelStatusText
            packetTunnelStatusText = "Configuration installed with \(excludedIPv4Addresses.count) excluded upstream IPs; tunnel is \(status)"
            statusText = packetTunnelStatusText
        } catch {
            packetTunnelStatusText = "Packet tunnel configuration failed: \(error)"
            statusText = packetTunnelStatusText
        }
    }

    func startPacketTunnel() async {
        do {
            await startLocalProxyStack()
            let excludedIPv4Addresses = await packetTunnelExcludedIPv4Addresses()
            try await PacketTunnelConfigurationManager.installOrUpdateConfiguration(
                httpPort: proxyListenPort,
                socksPort: socksListenPort,
                excludedIPv4Addresses: excludedIPv4Addresses
            )
            try await PacketTunnelConfigurationManager.startTunnel()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await refreshPacketTunnelStatus(updateStatusText: false)
            if packetTunnelConnected {
                packetTunnelStatusText = "Packet tunnel connected; excluding \(excludedIPv4Addresses.count) upstream IPs"
            } else {
                packetTunnelStatusText = "Packet tunnel start requested; current status is \(packetTunnelStatusText)"
            }
            statusText = packetTunnelStatusText
        } catch {
            packetTunnelStatusText = "Packet tunnel start failed: \(error)"
            statusText = packetTunnelStatusText
        }
    }

    func stopPacketTunnel() async {
        do {
            try await PacketTunnelConfigurationManager.stopTunnel()
            try? await Task.sleep(nanoseconds: 500_000_000)
            await refreshPacketTunnelStatus(updateStatusText: false)
            packetTunnelStatusText = "Packet tunnel stop requested; current status is \(packetTunnelStatusText)"
            statusText = packetTunnelStatusText
        } catch {
            packetTunnelStatusText = "Packet tunnel stop failed: \(error)"
            statusText = packetTunnelStatusText
        }
    }

    private func packetTunnelExcludedIPv4Addresses() async -> [String] {
        var addresses = Set([
            "1.1.1.1",
            "1.0.0.1",
            "8.8.8.8",
            "8.8.4.4",
            "9.9.9.9",
            "149.112.112.112",
            "223.5.5.5",
            "223.6.6.6"
        ])

        for proxy in profile.proxies where proxy.kind != .direct && proxy.kind != .reject {
            let host = proxy.host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, !Self.isLoopbackOrPrivateHost(host) else { continue }
            if let address = Self.normalizedIPv4Address(host) {
                addresses.insert(address)
                continue
            }

            let diagnostic = await ProxyUpstreamResolutionDiagnostics.evaluate(host: host)
            if let bypass = diagnostic.bypassIPv4Address {
                addresses.insert(bypass)
            }
            for address in diagnostic.systemIPv4Addresses where !Self.isFakeIPv4Address(address) {
                addresses.insert(address)
            }
        }

        let result = addresses.sorted()
        packetTunnelExcludedIPv4Summary = Self.packetTunnelExclusionSummary(result)
        return result
    }

    private static func packetTunnelExclusionSummary(_ addresses: [String]) -> String {
        guard !addresses.isEmpty else {
            return "No tunnel bypass addresses computed"
        }
        let preview = addresses.prefix(10).joined(separator: ", ")
        let suffix = addresses.count > 10 ? ", +\(addresses.count - 10) more" : ""
        return "Excluding DoH and active upstream addresses: \(preview)\(suffix)"
    }

    private static func normalizedIPv4Address(_ value: String) -> String? {
        var address = in_addr()
        guard value.withCString({ inet_pton(AF_INET, $0, &address) == 1 }) else {
            return nil
        }
        var copy = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &copy, &buffer, socklen_t(INET_ADDRSTRLEN))
        let endIndex = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(decoding: buffer[..<endIndex].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func isFakeIPv4Address(_ value: String) -> Bool {
        var address = in_addr()
        guard value.withCString({ inet_pton(AF_INET, $0, &address) == 1 }) else {
            return false
        }
        let numeric = UInt32(bigEndian: address.s_addr)
        return (numeric & 0xFFFE_0000) == 0xC612_0000
    }

    private static func isLoopbackOrPrivateHost(_ host: String) -> Bool {
        guard let address = normalizedIPv4Address(host) else {
            return host == "localhost" || host.hasSuffix(".local")
        }
        var parsed = in_addr()
        guard address.withCString({ inet_pton(AF_INET, $0, &parsed) == 1 }) else {
            return false
        }
        let value = UInt32(bigEndian: parsed.s_addr)
        return (value & 0xFF00_0000) == 0x7F00_0000
            || (value & 0xFF00_0000) == 0x0A00_0000
            || (value & 0xFFF0_0000) == 0xAC10_0000
            || (value & 0xFFFF_0000) == 0xC0A8_0000
            || (value & 0xFFFF_0000) == 0xA9FE_0000
    }

    func refreshPacketTunnelStatus() async {
        await refreshPacketTunnelStatus(updateStatusText: true)
    }

    private func refreshPacketTunnelStatus(updateStatusText: Bool) async {
        do {
            let snapshot = try await PacketTunnelConfigurationManager.statusSnapshot()
            packetTunnelStatusText = snapshot.text
            packetTunnelConnected = snapshot.isConnected
            packetTunnelTransitioning = snapshot.isTransitioning
            if updateStatusText {
                statusText = "Packet tunnel status: \(snapshot.text)"
            }
        } catch {
            packetTunnelStatusText = "Not configured"
            packetTunnelConnected = false
            packetTunnelTransitioning = false
            if updateStatusText {
                statusText = "Packet tunnel status unavailable: \(error)"
            }
        }
    }

    func restoreSystemProxyForTermination() {
        let service = networkServiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !service.isEmpty else { return }

        let commands: [MacProxySetupCommandInvocation]
        if let restorePoint = systemProxyRestorePoint {
            commands = restorePoint.restoreInvocations(networkService: service)
        } else if systemProxyStatus.activation == .active || systemProxyStatus.activation == .partial {
            commands = MacProxySetupCommands(networkService: service, httpPort: proxyListenPort, socksPort: socksListenPort).disableInvocations
        } else {
            return
        }

        guard !commands.isEmpty else { return }
        try? Self.runNetworkSetupSynchronously(commands)
    }

    private func captureSystemProxyRestorePointIfNeeded() async {
        guard systemProxyRestorePoint == nil else { return }

        await refreshSystemProxyStatus()
        guard systemProxyStatus.activation != .active else { return }
        systemProxyRestorePoint = systemProxyStatus
        persistSystemProxyRestorePoint()
        statusText = "Saved previous macOS proxy settings"
    }

    private func restorePreviousSystemProxySettings() async -> Bool {
        guard let restorePoint = systemProxyRestorePoint else {
            return false
        }

        let commands = restorePoint.restoreInvocations(networkService: networkServiceName)
        guard !commands.isEmpty else {
            systemProxyRestorePoint = nil
            persistSystemProxyRestorePoint()
            return false
        }

        let restored = await runSystemProxyCommands(
            commands: commands,
            successStatus: "Restored previous macOS proxy settings for \(networkServiceName)"
        )
        if restored {
            systemProxyRestorePoint = nil
            persistSystemProxyRestorePoint()
        }
        return restored
    }

    @discardableResult
    private func runSystemProxyCommands(commands: [MacProxySetupCommandInvocation], successStatus: String) async -> Bool {
        let service = networkServiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !service.isEmpty else {
            statusText = "System proxy update failed: network service is empty"
            return false
        }

        saveLocalState()
        systemProxyApplyInProgress = true
        statusText = "Updating macOS proxy settings..."
        defer { systemProxyApplyInProgress = false }

        do {
            try await Self.runNetworkSetup(commands)
            statusText = successStatus
            await refreshSystemProxyStatus()
            return true
        } catch {
            statusText = "System proxy update failed: \(error)"
            return false
        }
    }

    private func flushSystemNameCaches() async {
        await Self.runBestEffortCommand(executablePath: "/usr/bin/dscacheutil", arguments: ["-flushcache"])
        await Self.runBestEffortCommand(executablePath: "/usr/bin/killall", arguments: ["-HUP", "mDNSResponder"])
    }

    func refreshSystemProxyStatus() async {
        await refreshSystemProxyStatus(updateStatusText: true)
    }

    private func refreshSystemProxyStatus(updateStatusText: Bool) async {
        let service = networkServiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !service.isEmpty else {
            systemProxyStatus = .unknown(expectedHTTPPort: proxyListenPort, expectedSOCKSPort: socksListenPort)
            effectiveProxyStatus = .unknown(expectedHTTPPort: proxyListenPort, expectedSOCKSPort: socksListenPort)
            if updateStatusText {
                statusText = "System proxy status failed: network service is empty"
            }
            return
        }

        if updateStatusText {
            systemProxyStatusInProgress = true
        }
        defer {
            if updateStatusText {
                systemProxyStatusInProgress = false
            }
        }

        do {
            let outputs = try await Self.systemProxyStatusOutputs(service: service)
            systemProxyStatus = MacSystemProxyStatus(
                web: MacProxyEndpointStatus.parse(outputs.web),
                secureWeb: MacProxyEndpointStatus.parse(outputs.secureWeb),
                socks: MacProxyEndpointStatus.parse(outputs.socks),
                expectedHTTPPort: proxyListenPort,
                expectedSOCKSPort: socksListenPort
            )
            if let effectiveProxyOutput = try? await Self.effectiveProxyOutput() {
                effectiveProxyStatus = MacEffectiveProxyStatus.parseScutilProxy(
                    effectiveProxyOutput,
                    expectedHTTPPort: proxyListenPort,
                    expectedSOCKSPort: socksListenPort
                )
            } else {
                effectiveProxyStatus = .unknown(expectedHTTPPort: proxyListenPort, expectedSOCKSPort: socksListenPort)
            }
            if updateStatusText {
                statusText = "Configured \(networkServiceName): \(systemProxyStatus.activation.rawValue); effective: \(effectiveProxyStatus.summary)"
            }
        } catch {
            systemProxyStatus = .unknown(expectedHTTPPort: proxyListenPort, expectedSOCKSPort: socksListenPort)
            effectiveProxyStatus = .unknown(expectedHTTPPort: proxyListenPort, expectedSOCKSPort: socksListenPort)
            if updateStatusText {
                statusText = "System proxy status failed: \(error)"
            }
        }
    }

    private nonisolated static func networkServiceListOutput() async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            process.arguments = ["-listallnetworkservices"]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                let message = String(data: errorOutput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw NetworkServiceDetectionError.commandFailed(message?.isEmpty == false ? message! : "networksetup exited with \(process.terminationStatus)")
            }

            return String(data: output, encoding: .utf8) ?? ""
        }.value
    }

    private nonisolated static func runNetworkSetup(_ commands: [MacProxySetupCommandInvocation]) async throws {
        try await Task.detached(priority: .utility) {
            for command in commands {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: MacProxySetupCommandInvocation.executablePath)
                process.arguments = command.arguments

                let errorPipe = Pipe()
                process.standardError = errorPipe
                process.standardOutput = Pipe()

                try process.run()
                process.waitUntilExit()

                guard process.terminationStatus == 0 else {
                    let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: errorOutput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    throw NetworkServiceDetectionError.commandFailed(message?.isEmpty == false ? message! : "\(command.displayCommand) exited with \(process.terminationStatus)")
                }
            }
        }.value
    }

    private nonisolated static func runNetworkSetupSynchronously(_ commands: [MacProxySetupCommandInvocation]) throws {
        for command in commands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: MacProxySetupCommandInvocation.executablePath)
            process.arguments = command.arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NetworkServiceDetectionError.commandFailed("\(command.displayCommand) exited with \(process.terminationStatus)")
            }
        }
    }

    private nonisolated static func systemProxyStatusOutputs(service: String) async throws -> (web: String, secureWeb: String, socks: String) {
        async let web = networkSetupOutput(arguments: ["-getwebproxy", service])
        async let secureWeb = networkSetupOutput(arguments: ["-getsecurewebproxy", service])
        async let socks = networkSetupOutput(arguments: ["-getsocksfirewallproxy", service])
        return try await (web, secureWeb, socks)
    }

    private nonisolated static func networkSetupOutput(arguments: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: MacProxySetupCommandInvocation.executablePath)
            process.arguments = arguments

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                let message = String(data: errorOutput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw NetworkServiceDetectionError.commandFailed(message?.isEmpty == false ? message! : "networksetup exited with \(process.terminationStatus)")
            }
            return String(data: output, encoding: .utf8) ?? ""
        }.value
    }

    private nonisolated static func effectiveProxyOutput() async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
            process.arguments = ["--proxy"]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                let message = String(data: errorOutput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw NetworkServiceDetectionError.commandFailed(message?.isEmpty == false ? message! : "scutil exited with \(process.terminationStatus)")
            }
            return String(data: output, encoding: .utf8) ?? ""
        }.value
    }

    private nonisolated static func runBestEffortCommand(executablePath: String, arguments: [String]) async {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return
            }
        }.value
    }

    private nonisolated static func openChromeTestBrowser(httpPort: Int, socksPort: Int) async throws {
        try await Task.detached(priority: .utility) {
            let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            let profileDirectory = supportDirectory
                .appendingPathComponent("blaze", isDirectory: true)
                .appendingPathComponent("ChromeTestProfile", isDirectory: true)
            try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [
                "-na", "Google Chrome",
                "--args",
                "--user-data-dir=\(profileDirectory.path)",
                "--proxy-server=http=127.0.0.1:\(httpPort);https=127.0.0.1:\(httpPort);socks=socks5://127.0.0.1:\(socksPort)",
                "--disable-quic",
                "--no-first-run",
                "https://www.google.com/",
                "https://www.baidu.com/"
            ]
            process.standardOutput = Pipe()
            let errorPipe = Pipe()
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: errorOutput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw NetworkServiceDetectionError.commandFailed(message?.isEmpty == false ? message! : "open exited with \(process.terminationStatus)")
            }
        }.value
    }

    func saveLocalState() {
        defaults.set(sourceText, forKey: PersistenceKey.sourceText)
        defaults.set(remoteProfileURLText, forKey: PersistenceKey.remoteProfileURL)
        defaults.set(proxyListenPort, forKey: PersistenceKey.httpPort)
        defaults.set(socksListenPort, forKey: PersistenceKey.socksPort)
        defaults.set(selectedPolicies, forKey: PersistenceKey.selectedPolicies)
        defaults.set(networkServiceName, forKey: PersistenceKey.networkServiceName)
        defaults.set(proxyRoutingMode.rawValue, forKey: PersistenceKey.proxyRoutingMode)
        defaults.set(globalProxyPolicy, forKey: PersistenceKey.globalProxyPolicy)
        defaults.set(Array(favoriteProxyNames).sorted(), forKey: PersistenceKey.favoriteProxyNames)
        persistRuleSetCache()
        persistSystemProxyRestorePoint()
    }

    func clearLocalState() {
        for key in PersistenceKey.all {
            defaults.removeObject(forKey: key)
        }
        systemProxyRestorePoint = nil
        statusText = "Cleared saved local profile data"
    }

    func runLatencyChecks() async {
        statusText = "Checking endpoints..."
        latencyResults = [:]
        let candidates = profile.proxies.filter { $0.kind.isStandardTCPProbeable }
        guard !candidates.isEmpty else {
            statusText = "No probeable endpoints"
            return
        }

        for proxy in candidates {
            let result = await probe.measure(proxy: proxy)
            latencyResults[proxy.name] = result
        }
        statusText = "Checked \(candidates.count) endpoints; use Proxies > Apply Best to update auto groups"
    }

    func runLatencyCheck(proxyName: String) async {
        guard let proxy = profile.proxies.first(where: { $0.name == proxyName }) else {
            statusText = "Endpoint check failed: proxy not found"
            return
        }

        statusText = "Checking \(proxy.name)..."
        let result = await probe.measure(proxy: proxy)
        latencyResults[proxy.name] = result
        statusText = "\(proxy.name): \(result.milliseconds.map { "\($0) ms" } ?? result.status)"
    }

    func runConnectivityDiagnostics() async {
        guard !connectivityTestRunning else { return }
        connectivityTestRunning = true
        connectivityTestResults = []
        statusText = "Running connectivity diagnostics..."
        defer {
            connectivityTestRunning = false
        }

        await refreshSystemProxyStatus(updateStatusText: false)
        await refreshPacketTunnelStatus(updateStatusText: false)

        await appendPolicyDiagnostics()

        await appendConnectivityResult(
            ConnectivityTestResult(
                name: "Configured Proxy",
                transport: "networksetup",
                target: networkServiceName,
                status: systemProxyStatus.activation == .active ? .passed : .failed,
                detail: systemProxyStatus.summary,
                durationMilliseconds: nil
            )
        )
        await appendConnectivityResult(
            ConnectivityTestResult(
                name: "Browser Route",
                transport: "scutil",
                target: "Current effective route",
                status: browserTrafficShouldReachBlaze ? .passed : (effectiveProxyStatus.anyProxyEnabled ? .failed : .info),
                detail: browserTrafficShouldReachBlaze
                    ? (packetTunnelConnected ? "Packet tunnel is connected" : "Effective proxy is Blaze")
                    : "\(effectiveProxyStatus.summary); configured \(networkServiceName): \(systemProxyStatus.summary)",
                durationMilliseconds: nil
            )
        )
        await appendConnectivityResult(
            ConnectivityTestResult(
                name: "Packet Tunnel",
                transport: "Network Extension",
                target: "blaze Packet Tunnel",
                status: packetTunnelConnected ? .passed : .info,
                detail: packetTunnelStatusText,
                durationMilliseconds: nil
            )
        )

        let excludedIPv4Addresses = await packetTunnelExcludedIPv4Addresses()
        await appendConnectivityResult(
            ConnectivityTestResult(
                name: "Tunnel Bypass",
                transport: "Routing",
                target: "\(excludedIPv4Addresses.count) IPv4 addresses",
                status: excludedIPv4Addresses.isEmpty ? .failed : .passed,
                detail: Self.packetTunnelExclusionSummary(excludedIPv4Addresses),
                durationMilliseconds: nil
            )
        )

        await appendConnectivityResult(
            ConnectivityTestResult(
                name: "HTTP Listener",
                transport: "Local",
                target: "127.0.0.1:\(proxyListenPort)",
                status: proxyServerRunning ? .passed : .failed,
                detail: proxyServerRunning ? "HTTP listener is running" : "HTTP listener is stopped",
                durationMilliseconds: nil
            )
        )

        await appendConnectivityResult(
            ConnectivityTestResult(
                name: "SOCKS5 Listener",
                transport: "Local",
                target: "127.0.0.1:\(socksListenPort)",
                status: socksServerRunning ? .passed : .failed,
                detail: socksServerRunning ? "SOCKS5 listener is running" : "SOCKS5 listener is stopped",
                durationMilliseconds: nil
            )
        )

        if let proxy = diagnosticProxy(for: "www.google.com") {
            let dnsResult = await ConnectivityDNSProbe.evaluate(host: proxy.host, proxyName: proxy.name)
            await appendConnectivityResult(dnsResult)
        } else {
            await appendConnectivityResult(
                ConnectivityTestResult(
                    name: "Upstream DNS",
                    transport: "DNS",
                    target: "www.google.com",
                    status: .info,
                    detail: "No active proxy node resolved for Google route",
                    durationMilliseconds: nil
                )
            )
        }

        for target in ConnectivityTarget.defaultTargets {
            let httpResult = await ConnectivitySocketProbe.httpConnect(
                target: target,
                proxyPort: proxyListenPort
            )
            await appendConnectivityResult(httpResult)

            let fetchResult = await ConnectivityHTTPFetchProbe.fetch(
                target: target,
                proxyPort: proxyListenPort
            )
            await appendConnectivityResult(fetchResult)

            let socksResult = await ConnectivitySocketProbe.socks5Connect(
                target: target,
                proxyPort: socksListenPort
            )
            await appendConnectivityResult(socksResult)
        }

        let failures = connectivityTestResults.filter { $0.status == .failed }.count
        statusText = failures == 0 ? "Connectivity diagnostics passed" : "Connectivity diagnostics found \(failures) issue\(failures == 1 ? "" : "s")"
        await refreshProxyEvents()
    }

    private func appendPolicyDiagnostics() async {
        let ruleSetCount = profile.rules.filter { $0.type == "RULE-SET" }.count
        let ruleCacheDetail: String
        let ruleCacheStatus: ConnectivityTestStatus
        if ruleSetCount == 0 {
            ruleCacheDetail = "Profile has no RULE-SET entries"
            ruleCacheStatus = .info
        } else if importedRuleSetRuleCount == 0 {
            ruleCacheDetail = "\(ruleSetCount) RULE-SET entries are not downloaded; traffic can fall through to FINAL"
            ruleCacheStatus = .failed
        } else {
            ruleCacheDetail = "\(importedRuleSetRuleCount) rules loaded from \(ruleSetCount) RULE-SET entries"
            ruleCacheStatus = .passed
        }

        await appendConnectivityResult(
            ConnectivityTestResult(
                name: "Rule Cache",
                transport: "Rules",
                target: "\(ruleSetCount) remote sets",
                status: ruleCacheStatus,
                detail: ruleCacheDetail,
                durationMilliseconds: nil
            )
        )

        let modeDetail: String
        let modeStatus: ConnectivityTestStatus
        switch proxyRoutingMode {
        case .ruleBased:
            modeDetail = "Profile rules are active"
            modeStatus = .passed
        case .global:
            modeDetail = "Global mode bypasses profile rules and routes everything through \(resolvedGlobalProxyPolicy)"
            modeStatus = .failed
        case .direct:
            modeDetail = "Direct mode bypasses proxy outbounds"
            modeStatus = .failed
        }

        await appendConnectivityResult(
            ConnectivityTestResult(
                name: "Routing Mode",
                transport: "Policy",
                target: activeRoutingSummary,
                status: modeStatus,
                detail: modeDetail,
                durationMilliseconds: nil
            )
        )

        for target in ConnectivityTarget.defaultTargets {
            let host = target.url.host ?? target.url.absoluteString
            let result = RouteProbe(profile: activeRoutingProfile(), groupSelections: selectedPolicies).evaluate(host)
            await appendConnectivityResult(
                ConnectivityTestResult(
                    name: "\(target.name) Route",
                    transport: "Policy",
                    target: host,
                    status: .info,
                    detail: "\(result.rule) -> \(result.policyPath.isEmpty ? result.policy : result.policyPath)",
                    durationMilliseconds: nil
                )
            )
        }
    }

    func startLocalProxyServer() async {
        guard !proxyServerRunning else { return }
        saveLocalState()
        let logStore = proxyLogStore
        let server = LocalHTTPProxyServer(logStore: logStore, routingProfile: activeRoutingProfile(), groupSelections: selectedPolicies)

        do {
            try await server.start(port: proxyListenPort)
            proxyServer = server
            proxyServerRunning = true
            statusText = "HTTP proxy listening on 127.0.0.1:\(proxyListenPort)"
            startProxyEventRefresh()
        } catch {
            statusText = "Proxy start failed: \(error)"
        }
    }

    func stopLocalProxyServer() async {
        await proxyServer?.stop()
        proxyServer = nil
        proxyServerRunning = false
        await refreshProxyEvents()
        statusText = "HTTP proxy stopped"
        if !socksServerRunning {
            proxyRefreshTask?.cancel()
            proxyRefreshTask = nil
        }
    }

    func startLocalSocksServer() async {
        guard !socksServerRunning else { return }
        saveLocalState()
        let logStore = proxyLogStore
        let server = LocalSOCKS5ProxyServer(logStore: logStore, routingProfile: activeRoutingProfile(), groupSelections: selectedPolicies)

        do {
            try await server.start(port: socksListenPort)
            socksServer = server
            socksServerRunning = true
            statusText = "SOCKS5 proxy listening on 127.0.0.1:\(socksListenPort)"
            startProxyEventRefresh()
        } catch {
            statusText = "SOCKS5 start failed: \(error)"
        }
    }

    func stopLocalSocksServer() async {
        await socksServer?.stop()
        socksServer = nil
        socksServerRunning = false
        await refreshProxyEvents()
        statusText = "SOCKS5 proxy stopped"
        if !proxyServerRunning {
            proxyRefreshTask?.cancel()
            proxyRefreshTask = nil
        }
    }

    func refreshProxyEvents() async {
        proxyEvents = await proxyLogStore.events()
        proxyPolicyStats = await proxyLogStore.policyHitStats()
        proxyRuleStats = await proxyLogStore.ruleHitStats()
    }

    func clearProxyEvents() async {
        await proxyLogStore.clear()
        proxyEvents = []
        proxyPolicyStats = []
        proxyRuleStats = []
        statusText = "Proxy request log cleared"
    }

    private func appendConnectivityResult(_ result: ConnectivityTestResult) async {
        connectivityTestResults.append(result)
        await proxyLogStore.append(result.proxyEvent)
    }

    private func startProxyEventRefresh() {
        proxyRefreshTask?.cancel()
        let logStore = proxyLogStore
        proxyRefreshTask = Task { [weak self] in
            var nextSystemProxyRefresh = Date()
            while !Task.isCancelled {
                let events = await logStore.events()
                let stats = await logStore.policyHitStats()
                let ruleStats = await logStore.ruleHitStats()
                await MainActor.run {
                    self?.proxyEvents = events
                    self?.proxyPolicyStats = stats
                    self?.proxyRuleStats = ruleStats
                }
                if Date() >= nextSystemProxyRefresh {
                    await self?.refreshSystemProxyStatus(updateStatusText: false)
                    await self?.refreshPacketTunnelStatus(updateStatusText: false)
                    nextSystemProxyRefresh = Date().addingTimeInterval(3)
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    private func reconcileSelectedPolicies() {
        var next: [String: String] = [:]
        for group in profile.groups {
            if let existing = selectedPolicies[group.name], group.policies.contains(existing) {
                next[group.name] = existing
            } else if let first = group.policies.first {
                next[group.name] = first
            }
        }
        selectedPolicies = next
    }

    private func reconcileGlobalProxyPolicy() {
        if !availableGlobalPolicies.contains(globalProxyPolicy) {
            globalProxyPolicy = resolvedGlobalProxyPolicy
        }
    }

    private func reconcileRuleSets() {
        let urls = Set(profile.rules.filter { $0.type == "RULE-SET" }.map(\.value))
        ruleSetRulesByURL = ruleSetRulesByURL.filter { urls.contains($0.key) }
        ruleSetStatusByURL = ruleSetStatusByURL.filter { urls.contains($0.key) }
    }

    private func restoreRuleSetCache() {
        guard let data = try? Data(contentsOf: Self.ruleSetCacheURL()),
              let cache = try? JSONDecoder().decode(RuleSetCache.self, from: data)
        else {
            reconcileRuleSets()
            return
        }

        ruleSetRulesByURL = cache.rulesByURL
        ruleSetStatusByURL = cache.statusByURL
        reconcileRuleSets()
        runRuleProbe()
    }

    private func persistRuleSetCache() {
        let cache = RuleSetCache(rulesByURL: ruleSetRulesByURL, statusByURL: ruleSetStatusByURL)
        guard let data = try? JSONEncoder().encode(cache) else { return }

        let url = Self.ruleSetCacheURL()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            // Cache persistence is best-effort; imported rules remain active in memory.
        }
    }

    private nonisolated static func ruleSetCacheURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("blaze", isDirectory: true)
            .appendingPathComponent("rule-set-cache.json", isDirectory: false)
    }

    private func activeRoutingProfile() -> ProxyProfile {
        let expanded = profile.replacingRules(profile.expandedRules(ruleSetsByURL: ruleSetRulesByURL))
        switch proxyRoutingMode {
        case .ruleBased:
            return expanded
        case .direct:
            return expanded.replacingRules([
                ProxyRule(type: "FINAL", value: "", policy: "DIRECT", options: [], sourceLine: -1, rawLine: "FINAL,DIRECT")
            ])
        case .global:
            let policy = resolvedGlobalProxyPolicy
            return expanded.replacingRules([
                ProxyRule(type: "FINAL", value: "", policy: policy, options: [], sourceLine: -1, rawLine: "FINAL,\(policy)")
            ])
        }
    }

    private func diagnosticProxy(for input: String) -> ProxyNode? {
        let result = RouteProbe(profile: activeRoutingProfile(), groupSelections: selectedPolicies).evaluate(input)
        for policy in result.policyPath.components(separatedBy: " -> ").reversed() {
            if let proxy = profile.proxies.first(where: { $0.name == policy }) {
                return proxy
            }
        }
        return nil
    }

    private func restoreSavedSystemProxyRestorePoint() {
        guard let data = defaults.data(forKey: PersistenceKey.systemProxyRestorePoint) else {
            systemProxyRestorePoint = nil
            return
        }

        systemProxyRestorePoint = try? JSONDecoder().decode(MacSystemProxyStatus.self, from: data)
    }

    private func persistSystemProxyRestorePoint() {
        guard let systemProxyRestorePoint,
              let data = try? JSONEncoder().encode(systemProxyRestorePoint) else {
            defaults.removeObject(forKey: PersistenceKey.systemProxyRestorePoint)
            return
        }

        defaults.set(data, forKey: PersistenceKey.systemProxyRestorePoint)
    }
}

private enum PersistenceKey {
    static let sourceText = "profile.sourceText"
    static let remoteProfileURL = "profile.remoteURL"
    static let httpPort = "server.httpPort"
    static let socksPort = "server.socksPort"
    static let selectedPolicies = "groups.selectedPolicies"
    static let networkServiceName = "systemProxy.networkServiceName"
    static let systemProxyRestorePoint = "systemProxy.restorePoint"
    static let proxyRoutingMode = "policy.routingMode"
    static let globalProxyPolicy = "policy.globalProxyPolicy"
    static let favoriteProxyNames = "proxies.favoriteNames"

    static let all = [sourceText, remoteProfileURL, httpPort, socksPort, selectedPolicies, networkServiceName, systemProxyRestorePoint, proxyRoutingMode, globalProxyPolicy, favoriteProxyNames]
}

private struct RuleSetCache: Codable {
    var rulesByURL: [String: [ProxyRule]]
    var statusByURL: [String: String]
}

private struct ConnectivityTarget: Sendable {
    var name: String
    var url: URL
    var expectedStatus: ClosedRange<Int>

    static let defaultTargets: [ConnectivityTarget] = [
        ConnectivityTarget(name: "Google", url: URL(string: "https://www.google.com/generate_204")!, expectedStatus: 204...204),
        ConnectivityTarget(name: "Baidu", url: URL(string: "https://www.baidu.com/")!, expectedStatus: 200...399),
        ConnectivityTarget(name: "ChatGPT", url: URL(string: "https://chatgpt.com/")!, expectedStatus: 200...499)
    ]
}

private enum ConnectivityHTTPFetchProbe {
    static func fetch(target: ConnectivityTarget, proxyPort: Int) async -> ConnectivityTestResult {
        let start = Date()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
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

        var request = URLRequest(url: target.url)
        request.setValue("blaze-connectivity-test", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (_, response) = try await session.data(for: request)
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            guard let httpResponse = response as? HTTPURLResponse else {
                return ConnectivityTestResult(
                    name: target.name,
                    transport: "HTTP Fetch",
                    target: target.url.host ?? target.url.absoluteString,
                    status: .failed,
                    detail: "No HTTP response",
                    durationMilliseconds: elapsed
                )
            }
            let code = httpResponse.statusCode
            return ConnectivityTestResult(
                name: target.name,
                transport: "HTTP Fetch",
                target: target.url.host ?? target.url.absoluteString,
                status: target.expectedStatus.contains(code) ? .passed : .failed,
                detail: "HTTP fetch returned \(code)",
                durationMilliseconds: elapsed
            )
        } catch {
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            return ConnectivityTestResult(
                name: target.name,
                transport: "HTTP Fetch",
                target: target.url.host ?? target.url.absoluteString,
                status: .failed,
                detail: errorDescription(error),
                durationMilliseconds: elapsed
            )
        }
    }

    private static func errorDescription(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return nsError.localizedDescription
        }
        return String(describing: error)
    }
}

private enum ConnectivitySocketProbe {
    static func httpConnect(target: ConnectivityTarget, proxyPort: Int) async -> ConnectivityTestResult {
        await Task.detached(priority: .utility) {
            let start = Date()
            let host = target.url.host ?? target.url.absoluteString
            do {
                let fd = try openLocalSocket(port: proxyPort, timeoutSeconds: 18)
                defer { close(fd) }
                let request = """
                CONNECT \(host):443 HTTP/1.1\r
                Host: \(host):443\r
                Proxy-Connection: close\r
                User-Agent: blaze-connectivity-test\r
                \r
                
                """
                try sendAll(Data(request.utf8), to: fd)
                let header = try readUntilHeaderTerminator(from: fd, timeoutSeconds: 18)
                let statusLine = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
                let code = statusCode(from: statusLine)
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                return ConnectivityTestResult(
                    name: target.name,
                    transport: "HTTP CONNECT",
                    target: host,
                    status: code == 200 ? .passed : .failed,
                    detail: code.map { "HTTP proxy returned \($0)" } ?? "Invalid HTTP proxy response",
                    durationMilliseconds: elapsed
                )
            } catch {
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                return ConnectivityTestResult(
                    name: target.name,
                    transport: "HTTP CONNECT",
                    target: host,
                    status: .failed,
                    detail: errorDescription(error),
                    durationMilliseconds: elapsed
                )
            }
        }.value
    }

    static func socks5Connect(target: ConnectivityTarget, proxyPort: Int) async -> ConnectivityTestResult {
        await Task.detached(priority: .utility) {
            let start = Date()
            let host = target.url.host ?? target.url.absoluteString
            do {
                let fd = try openLocalSocket(port: proxyPort, timeoutSeconds: 18)
                defer { close(fd) }

                try sendAll(Data([0x05, 0x01, 0x00]), to: fd)
                let greeting = try readExact(2, from: fd)
                guard greeting == [0x05, 0x00] else {
                    throw ConnectivitySocketError.protocolFailure("SOCKS5 auth response \(hex(greeting))")
                }

                let hostBytes = Array(host.utf8)
                guard hostBytes.count <= 255 else {
                    throw ConnectivitySocketError.protocolFailure("Target host is too long")
                }
                var request = Data([0x05, 0x01, 0x00, 0x03, UInt8(hostBytes.count)])
                request.append(contentsOf: hostBytes)
                request.append(contentsOf: [0x01, 0xBB])
                try sendAll(request, to: fd)

                let response = try readExact(4, from: fd)
                let replyCode = response[1]
                try consumeSOCKSAddress(atyp: response[3], from: fd)
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                return ConnectivityTestResult(
                    name: target.name,
                    transport: "SOCKS5 CONNECT",
                    target: host,
                    status: replyCode == 0x00 ? .passed : .failed,
                    detail: replyCode == 0x00 ? "SOCKS5 CONNECT accepted" : "SOCKS5 reply code 0x\(String(format: "%02X", replyCode))",
                    durationMilliseconds: elapsed
                )
            } catch {
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                return ConnectivityTestResult(
                    name: target.name,
                    transport: "SOCKS5 CONNECT",
                    target: host,
                    status: .failed,
                    detail: errorDescription(error),
                    durationMilliseconds: elapsed
                )
            }
        }.value
    }

    private static func openLocalSocket(port: Int, timeoutSeconds: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ConnectivitySocketError.posix("socket", errno)
        }

        do {
            try configureTimeout(fd: fd, seconds: timeoutSeconds)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 else {
                throw ConnectivitySocketError.posix("connect", errno)
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func configureTimeout(fd: Int32, seconds: Int) throws {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw ConnectivitySocketError.posix("setsockopt SO_RCVTIMEO", errno)
        }
        guard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw ConnectivitySocketError.posix("setsockopt SO_SNDTIMEO", errno)
        }
    }

    private static func sendAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let count = Darwin.send(fd, baseAddress.advanced(by: sent), data.count - sent, 0)
                guard count > 0 else {
                    throw ConnectivitySocketError.posix("send", errno)
                }
                sent += count
            }
        }
    }

    private static func readExact(_ count: Int, from fd: Int32) throws -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: count)
        while result.count < count {
            let readCount = recv(fd, &buffer, count - result.count, 0)
            guard readCount > 0 else {
                throw ConnectivitySocketError.posix(readCount == 0 ? "recv EOF" : "recv", readCount == 0 ? ECONNRESET : errno)
            }
            result.append(contentsOf: buffer.prefix(readCount))
        }
        return result
    }

    private static func readUntilHeaderTerminator(from fd: Int32, timeoutSeconds _: Int) throws -> Data {
        var data = Data()
        let terminator = Data([13, 10, 13, 10])
        var buffer = [UInt8](repeating: 0, count: 1024)
        while data.count < 64 * 1024 {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else {
                throw ConnectivitySocketError.posix(count == 0 ? "recv EOF" : "recv", count == 0 ? ECONNRESET : errno)
            }
            data.append(contentsOf: buffer.prefix(count))
            if data.range(of: terminator) != nil {
                return data
            }
        }
        throw ConnectivitySocketError.protocolFailure("HTTP response headers exceeded 64 KiB")
    }

    private static func consumeSOCKSAddress(atyp: UInt8, from fd: Int32) throws {
        switch atyp {
        case 0x01:
            _ = try readExact(4 + 2, from: fd)
        case 0x03:
            let length = try readExact(1, from: fd)[0]
            _ = try readExact(Int(length) + 2, from: fd)
        case 0x04:
            _ = try readExact(16 + 2, from: fd)
        default:
            throw ConnectivitySocketError.protocolFailure("Unknown SOCKS5 address type 0x\(String(format: "%02X", atyp))")
        }
    }

    private static func statusCode(from statusLine: String) -> Int? {
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }

    private static func errorDescription(_ error: Error) -> String {
        if let socketError = error as? ConnectivitySocketError {
            return socketError.description
        }
        return String(describing: error)
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

private enum ConnectivitySocketError: Error, CustomStringConvertible {
    case posix(String, Int32)
    case protocolFailure(String)

    var description: String {
        switch self {
        case .posix(let operation, let code):
            "\(operation) failed: \(String(cString: strerror(code)))"
        case .protocolFailure(let message):
            message
        }
    }
}

private enum ConnectivityDNSProbe {
    static func evaluate(host: String, proxyName: String) async -> ConnectivityTestResult {
        let diagnostic = await ProxyUpstreamResolutionDiagnostics.evaluate(host: host)
        guard !diagnostic.systemIPv4Addresses.isEmpty else {
            return ConnectivityTestResult(
                name: "Upstream DNS",
                transport: "DNS",
                target: proxyName,
                status: .failed,
                detail: "No IPv4 address resolved for active upstream",
                durationMilliseconds: nil
            )
        }

        let detail: String
        if diagnostic.fakeIPDetected, let bypassIPv4Address = diagnostic.bypassIPv4Address {
            detail = "System DNS returns 198.18 fake-ip; bypass resolves \(bypassIPv4Address)"
        } else if diagnostic.fakeIPDetected {
            detail = "System DNS returns 198.18 fake-ip and bypass resolution failed"
        } else {
            detail = "Active upstream resolves outside fake-ip range"
        }

        return ConnectivityTestResult(
            name: "Upstream DNS",
            transport: "DNS",
            target: proxyName,
            status: diagnostic.canConnectWithoutFakeIP ? .passed : .failed,
            detail: detail,
            durationMilliseconds: nil
        )
    }
}

private extension ConnectivityTestResult {
    var proxyEvent: ProxyServerEvent {
        let parsedURL = URL(string: target.contains("://") ? target : "https://\(target)")
        return ProxyServerEvent(
            date: date,
            method: "DIAG",
            target: target,
            host: parsedURL?.host ?? target,
            port: parsedURL?.port ?? 443,
            policy: transport,
            status: status.rawValue,
            rule: "Connectivity",
            note: "\(name): \(detail); duration=\(durationText)"
        )
    }
}

private enum NetworkServiceDetectionError: Error, CustomStringConvertible {
    case commandFailed(String)

    var description: String {
        switch self {
        case .commandFailed(let message):
            message
        }
    }
}
