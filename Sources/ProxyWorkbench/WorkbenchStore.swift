import AppKit
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

    private let probe = LatencyProbe()
    private var proxyLogStore = ProxyEventStore(diskLogURL: ProxyEventStore.defaultDiskLogURL())
    private var proxyServer: LocalHTTPProxyServer?
    private var socksServer: LocalSOCKS5ProxyServer?
    private var proxyRefreshTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private var didLoadInitialProfile = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
            statusText = "Restored saved profile"
        } else {
            profile = .empty
            profileSummary = .empty
            sanitizedExport = ProfileExporter.sanitizedJSON(from: profile)
            statusText = "Paste a profile URL or import a local profile to begin"
        }

        Task {
            await refreshSystemProxyStatus()
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

    func applySystemProxySettings() async {
        await captureSystemProxyRestorePointIfNeeded()
        await runSystemProxyCommands(
            commands: MacProxySetupCommands(networkService: networkServiceName, httpPort: proxyListenPort, socksPort: socksListenPort).enableInvocations,
            successStatus: "Applied macOS proxy settings for \(networkServiceName)"
        )
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

    func refreshSystemProxyStatus() async {
        await refreshSystemProxyStatus(updateStatusText: true)
    }

    private func refreshSystemProxyStatus(updateStatusText: Bool) async {
        let service = networkServiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !service.isEmpty else {
            systemProxyStatus = .unknown(expectedHTTPPort: proxyListenPort, expectedSOCKSPort: socksListenPort)
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
            if updateStatusText {
                statusText = "System proxy status: \(systemProxyStatus.activation.rawValue)"
            }
        } catch {
            systemProxyStatus = .unknown(expectedHTTPPort: proxyListenPort, expectedSOCKSPort: socksListenPort)
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
        await appendConnectivityResult(
            ConnectivityTestResult(
                name: "System Proxy",
                transport: "macOS",
                target: networkServiceName,
                status: systemProxyStatus.activation == .active ? .passed : .failed,
                detail: systemProxyStatus.summary,
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
            let dnsResult = ConnectivityDNSProbe.evaluate(host: proxy.host, proxyName: proxy.name)
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

private struct ConnectivityTarget: Sendable {
    var name: String
    var url: URL
    var expectedStatus: ClosedRange<Int>

    static let defaultTargets: [ConnectivityTarget] = [
        ConnectivityTarget(name: "Google", url: URL(string: "https://www.google.com/generate_204")!, expectedStatus: 204...204),
        ConnectivityTarget(name: "Baidu", url: URL(string: "https://www.baidu.com/")!, expectedStatus: 200...399)
    ]
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
                    transport: "HTTP",
                    target: host,
                    status: code == 200 ? .passed : .failed,
                    detail: code.map { "HTTP proxy returned \($0)" } ?? "Invalid HTTP proxy response",
                    durationMilliseconds: elapsed
                )
            } catch {
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                return ConnectivityTestResult(
                    name: target.name,
                    transport: "HTTP",
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
                    transport: "SOCKS5",
                    target: host,
                    status: replyCode == 0x00 ? .passed : .failed,
                    detail: replyCode == 0x00 ? "SOCKS5 CONNECT accepted" : "SOCKS5 reply code 0x\(String(format: "%02X", replyCode))",
                    durationMilliseconds: elapsed
                )
            } catch {
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                return ConnectivityTestResult(
                    name: target.name,
                    transport: "SOCKS5",
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
    static func evaluate(host: String, proxyName: String) -> ConnectivityTestResult {
        let addresses = resolvedIPv4Addresses(for: host)
        guard !addresses.isEmpty else {
            return ConnectivityTestResult(
                name: "Upstream DNS",
                transport: "DNS",
                target: proxyName,
                status: .failed,
                detail: "No IPv4 address resolved for active upstream",
                durationMilliseconds: nil
            )
        }

        let isFakeIP = addresses.allSatisfy { ($0 & 0xFFFE_0000) == 0xC612_0000 }
        return ConnectivityTestResult(
            name: "Upstream DNS",
            transport: "DNS",
            target: proxyName,
            status: isFakeIP ? .failed : .passed,
            detail: isFakeIP ? "Active upstream resolves to 198.18.0.0/15 fake-ip" : "Active upstream resolves outside fake-ip range",
            durationMilliseconds: nil
        )
    }

    private static func resolvedIPv4Addresses(for host: String) -> [UInt32] {
        var hints = addrinfo(
            ai_flags: AI_NUMERICSERV,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var info: UnsafeMutablePointer<addrinfo>?
        let lookup = getaddrinfo(host, "443", &hints, &info)
        guard lookup == 0, let first = info else {
            return []
        }
        defer { freeaddrinfo(first) }

        var result: [UInt32] = []
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let address = current {
            if let socketAddress = address.pointee.ai_addr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0.pointee }) {
                result.append(UInt32(bigEndian: socketAddress.sin_addr.s_addr))
            }
            current = address.pointee.ai_next
        }
        return result
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
