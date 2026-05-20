import AppKit
import CFNetwork
import Darwin
import Foundation
import os.log
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

    var isBlockingStartupFailure: Bool {
        guard status == .failed else { return false }
        if transport == "Policy", name.hasSuffix(" Route") {
            return false
        }
        if transport == "HTTP CONNECT" {
            return false
        }
        if transport == "HTTP Fetch" {
            return false
        }
        if transport == "SOCKS5 CONNECT" {
            return false
        }
        if transport == "SOCKS5 Fetch" {
            return true
        }
        return true
    }
}

enum StartupWorkflowStepStatus: String, Hashable, Sendable {
    case pending = "Pending"
    case running = "Running"
    case passed = "Passed"
    case failed = "Failed"
    case actionNeeded = "Action Needed"
    case info = "Info"
}

struct StartupWorkflowStep: Identifiable, Hashable, Sendable {
    let id: Int
    var title: String
    var actionTitle: String
    var target: String
    var status: StartupWorkflowStepStatus
    var detail: String
    var updatedAt: Date?

    static func defaults() -> [StartupWorkflowStep] {
        [
            StartupWorkflowStep(
                id: 1,
                title: "Surge Preflight",
                actionTitle: "Close",
                target: "Surge or external proxy",
                status: .pending,
                detail: "Not checked"
            ),
            StartupWorkflowStep(
                id: 2,
                title: "System Extension",
                actionTitle: "Request",
                target: SystemExtensionController.extensionIdentifier,
                status: .pending,
                detail: "Not checked"
            ),
            StartupWorkflowStep(
                id: 3,
                title: "Local Listeners",
                actionTitle: "Start",
                target: "HTTP and SOCKS5",
                status: .pending,
                detail: "Not started"
            ),
            StartupWorkflowStep(
                id: 4,
                title: "Tunnel Config",
                actionTitle: "Install",
                target: "Packet Tunnel provider configuration",
                status: .pending,
                detail: "Not installed"
            ),
            StartupWorkflowStep(
                id: 5,
                title: "Global VPN",
                actionTitle: "Start",
                target: "Packet Tunnel connection",
                status: .pending,
                detail: "Not connected"
            ),
            StartupWorkflowStep(
                id: 6,
                title: "Tunnel Counters",
                actionTitle: "Read",
                target: "Packet flow diagnostics",
                status: .pending,
                detail: "No counters loaded"
            ),
            StartupWorkflowStep(
                id: 7,
                title: "Connectivity Tests",
                actionTitle: "Test",
                target: "Google, Baidu, ChatGPT, DNS, HTTP, SOCKS5",
                status: .pending,
                detail: "Not run"
            ),
            StartupWorkflowStep(
                id: 8,
                title: "Surge Restore",
                actionTitle: "Restart",
                target: "Restore Surge when Blaze VPN is done",
                status: .pending,
                detail: "No restore decision yet"
            )
        ]
    }
}

struct SurgeAppSnapshot: Hashable, Sendable {
    var isRunning: Bool
    var appName: String
    var bundleIdentifier: String?
    var bundlePath: String?
    var processIdentifier: Int32?
    var networkTunnelStatus: String

    static let notRunning = SurgeAppSnapshot(
        isRunning: false,
        appName: "Surge",
        bundleIdentifier: nil,
        bundlePath: nil,
        processIdentifier: nil,
        networkTunnelStatus: "Not checked"
    )

    var summary: String {
        if isRunning {
            return "Running\(bundleIdentifier.map { " (\($0))" } ?? "")"
        }
        return "Not running"
    }

    var restoreLabel: String {
        bundleIdentifier ?? bundlePath ?? appName
    }

    var hasConnectedNetworkTunnel: Bool {
        networkTunnelStatus.localizedCaseInsensitiveContains("is connected")
    }
}

struct SystemExtensionInstallSnapshot: Hashable, Sendable {
    var hostVersion: String
    var hostBuild: String
    var bundledVersion: String
    var bundledBuild: String
    var activeVersion: String?
    var activeBuild: String?
    var statusLine: String

    var isActiveLatest: Bool {
        guard let activeVersion, let activeBuild else { return false }
        return activeVersion == bundledVersion && activeBuild == bundledBuild
    }

    var summary: String {
        let active = activeVersion.map { "\($0)/\(activeBuild ?? "?")" } ?? "not active"
        return "app \(hostVersion)/\(hostBuild), bundled \(bundledVersion)/\(bundledBuild), active \(active)"
    }

    var hostText: String {
        "\(hostVersion)/\(hostBuild)"
    }

    var bundledText: String {
        "\(bundledVersion)/\(bundledBuild)"
    }

    var activeText: String {
        activeVersion.map { "\($0)/\(activeBuild ?? "?")" } ?? "not active"
    }

    var detail: String {
        if isActiveLatest {
            return "Active system extension matches bundled build \(bundledVersion)/\(bundledBuild)"
        }
        return "Active system extension does not match bundled build; \(summary); \(statusLine)"
    }
}

struct AppTrustSnapshot: Hashable, Sendable {
    var hostVersion: String
    var hostBuild: String
    var accepted: Bool
    var exitCode: Int32
    var statusLine: String
    var sourceLine: String?
    var originLine: String?

    var summary: String {
        let state = accepted ? "accepted" : "rejected"
        return "app \(hostVersion)/\(hostBuild), \(state), \(sourceLine ?? "source unknown")"
    }

    var detail: String {
        [
            statusLine,
            sourceLine,
            originLine,
            accepted ? nil : "spctl exit \(exitCode)"
        ]
        .compactMap { value -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        .joined(separator: "; ")
    }
}

private struct CommandOutputResult: Sendable {
    var exitCode: Int32
    var output: String
    var errorOutput: String

    var combinedText: String {
        [output, errorOutput]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
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
    @Published private(set) var startupWorkflowRunning = false
    @Published private(set) var startupWorkflowSteps: [StartupWorkflowStep] = StartupWorkflowStep.defaults()
    @Published private(set) var startupWatchdogText = "Idle"
    @Published private(set) var surgeAppSnapshot: SurgeAppSnapshot = .notRunning
    @Published private(set) var surgeRestoreText = "No restore candidate"
    @Published private(set) var packetTunnelStatusText = "System extension not installed"
    @Published private(set) var packetTunnelConnected = false
    @Published private(set) var packetTunnelTransitioning = false
    @Published private(set) var packetTunnelHostEntitlementText = SystemExtensionController.hostEntitlementStatusText
    @Published private(set) var packetTunnelExcludedIPv4Summary = "Not computed"
    @Published private(set) var packetTunnelDiagnosticsText = "Not queried"
    @Published private(set) var packetTunnelDiagnosticsSnapshot: PacketTunnelDiagnosticsSnapshot?
    @Published private(set) var packetTunnelConfigurationSnapshot: PacketTunnelConfigurationSnapshot?
    @Published private(set) var packetTunnelConfigurationText = "Not loaded"
    @Published private(set) var packetTunnelLastDiagnosticsRefreshText = "Never"
    @Published private(set) var systemExtensionInstallSnapshot: SystemExtensionInstallSnapshot?
    @Published private(set) var systemExtensionInstallText = "Not checked"
    @Published private(set) var appTrustSnapshot: AppTrustSnapshot?
    @Published private(set) var appTrustText = "Not checked"

    private let probe = LatencyProbe()
    private let systemExtensionController = SystemExtensionController()
    private var proxyLogStore = ProxyEventStore(diskLogURL: ProxyEventStore.defaultDiskLogURL())
    private var proxyServer: LocalHTTPProxyServer?
    private var socksServer: LocalSOCKS5ProxyServer?
    private let leafController = LeafController(
        binaryURL: WorkbenchStore.embeddedLeafBinaryURL(),
        runtimeDir: WorkbenchStore.leafRuntimeDir()
    )

    private static func embeddedLeafBinaryURL() -> URL {
        if let url = Bundle.main.url(forResource: "leaf", withExtension: nil) {
            return url
        }
        // Fallback for dev runs (swift run blaze) — pick the Vendor binary
        // built locally so the workflow still works outside the bundle.
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd)
            .appendingPathComponent("Vendor/Leaf/macos-arm64/leaf")
    }

    private static func leafRuntimeDir() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("blaze/leaf", isDirectory: true)
    }
    private var proxyRefreshTask: Task<Void, Never>?
    private var startupWatchdogTask: Task<Void, Never>?
    private var startupWatchdogDeadline: Date?
    private var startupWatchdogRecoveryInProgress = false
    private var surgeRestoreCandidate: SurgeAppSnapshot?
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

    var packetTunnelDebugSubtitle: String {
        if packetTunnelConnected {
            return "Connected, \(packetTunnelConfigurationSnapshot?.packetEngine ?? "unknown") engine"
        }
        if packetTunnelTransitioning {
            return "Transitioning, \(packetTunnelStatusText)"
        }
        return packetTunnelStatusText
    }

    var startupWorkflowSubtitle: String {
        if startupWorkflowRunning {
            return "Running startup flow"
        }
        let failed = startupWorkflowSteps.filter { $0.status == .failed }.count
        if failed > 0 {
            return "\(failed) startup step\(failed == 1 ? "" : "s") failed"
        }
        let actionNeeded = startupWorkflowSteps.filter { $0.status == .actionNeeded }.count
        if actionNeeded > 0 {
            return "\(actionNeeded) startup step\(actionNeeded == 1 ? "" : "s") need approval or retry"
        }
        let passed = startupWorkflowSteps.filter { $0.status == .passed }.count
        return "\(passed) of \(startupWorkflowSteps.count) startup steps passed"
    }

    var surgeConflictSummary: String {
        if surgeAppSnapshot.isRunning {
            return surgeAppSnapshot.summary
        }
        if surgeAppSnapshot.hasConnectedNetworkTunnel {
            return "Surge VPN active"
        }
        if effectiveProxyStatus.anyProxyEnabled && !effectiveProxyStatus.matchesBlaze && !packetTunnelConnected {
            return "Other proxy active"
        }
        return surgeAppSnapshot.networkTunnelStatus == "Not checked" ? "Not checked" : "Clear"
    }

    private var surgeConflictTestStatus: ConnectivityTestStatus {
        if packetTunnelConnected && (surgeAppSnapshot.isRunning || surgeAppSnapshot.hasConnectedNetworkTunnel) {
            return .failed
        }
        if !packetTunnelConnected && effectiveProxyStatus.anyProxyEnabled && !effectiveProxyStatus.matchesBlaze {
            return .failed
        }
        if surgeAppSnapshot.hasConnectedNetworkTunnel && !packetTunnelConnected {
            return .failed
        }
        return .info
    }

    private var surgeConflictTestDetail: String {
        if packetTunnelConnected && (surgeAppSnapshot.isRunning || surgeAppSnapshot.hasConnectedNetworkTunnel) {
            return "Surge app or VPN service is active while Blaze Packet Tunnel is connected; it may retake DNS or utun"
        }
        if !packetTunnelConnected && effectiveProxyStatus.anyProxyEnabled && !effectiveProxyStatus.matchesBlaze {
            return "Effective proxy is not Blaze: \(effectiveProxyStatus.summary)"
        }
        return "\(surgeAppSnapshot.summary); \(surgeAppSnapshot.networkTunnelStatus)"
    }

    private var startupConnectivityPassed: Bool {
        startupWorkflowSteps.first(where: { $0.id == 7 })?.status == .passed
            && Self.blockingConnectivityFailures(in: connectivityTestResults).isEmpty
    }

    private var startupWatchdogShouldRecover: Bool {
        let vpnOrExternalProxyWasTouched = packetTunnelConnected
            || surgeRestoreCandidate != nil
            || startupWorkflowSteps.contains { $0.id >= 5 && $0.updatedAt != nil }
        return vpnOrExternalProxyWasTouched
    }

    private var recentCriticalProxyFailures: [ProxyServerEvent] {
        proxyEvents.filter { event in
            let note = event.note.lowercased()
            return note.contains("fake-ip dns bypass failed")
                || note.contains("upstream dns bypass failed")
                || note.contains("local dns resolved upstream to 198.18")
                || note.contains("no upstream response bytes")
                || note.contains("operation canceled")
                || note.contains("connection reset by peer")
        }
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
            await refreshPacketTunnelConfiguration(updateStatusText: false)
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
            await refreshPacketTunnelConfiguration(updateStatusText: false)
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

    func stopPacketTunnelAndRestoreSurge() async {
        stopStartupWatchdog(markCompleted: false)
        await stopPacketTunnel()
        await refreshSurgeStatus(updateStatusText: false)
        guard !packetTunnelConnected else {
            statusText = "Surge restore skipped because Packet Tunnel is still connected"
            return
        }
        _ = await restoreSurgeAfterBlazeIfSafe(stepID: 8)
        updateStartupWorkflowFromCurrentState()
        statusText = startupWorkflowSubtitle
    }

    func runStartupWatchdogRecoveryNow(reason: String = "Manual recovery requested") async {
        await recoverFromStartupWatchdog(reason: reason)
    }

    func refreshSurgeStatus() async {
        await refreshSurgeStatus(updateStatusText: true)
    }

    private func refreshSurgeStatus(updateStatusText: Bool) async {
        var snapshot = Self.detectSurgeApp()
        snapshot.networkTunnelStatus = (try? await Self.surgeNetworkTunnelStatus()) ?? "Surge VPN status unavailable"
        surgeAppSnapshot = snapshot
        if updateStatusText {
            statusText = "Surge status: \(surgeAppSnapshot.summary); \(surgeAppSnapshot.networkTunnelStatus)"
        }
    }

    private func refreshSystemExtensionInstallStatus(updateStatusText: Bool) async {
        let snapshot = await Self.systemExtensionInstallSnapshot()
        systemExtensionInstallSnapshot = snapshot
        systemExtensionInstallText = snapshot.summary
        if updateStatusText {
            statusText = snapshot.detail
        }
    }

    private func refreshAppTrustStatus(updateStatusText: Bool) async {
        let snapshot = await Self.appTrustSnapshot()
        appTrustSnapshot = snapshot
        appTrustText = snapshot.summary
        if updateStatusText {
            statusText = snapshot.detail
        }
    }

    private func prepareSurgeForBlaze() async -> Bool {
        var prepared = true

        if surgeAppSnapshot.hasConnectedNetworkTunnel {
            do {
                try await Self.stopSurgeVPNServiceIfAvailable()
            } catch {
                statusText = "Failed to stop Surge VPN service: \(error)"
                prepared = false
            }

            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                await refreshSurgeStatus(updateStatusText: false)
                if !surgeAppSnapshot.hasConnectedNetworkTunnel {
                    break
                }
            }

            if surgeAppSnapshot.hasConnectedNetworkTunnel {
                return false
            }
        }

        let runningApps = Self.runningSurgeApplications()
        guard !runningApps.isEmpty else { return prepared }

        for app in runningApps {
            _ = app.terminate()
        }

        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Self.runningSurgeApplications().isEmpty {
                return prepared
            }
        }

        for app in Self.runningSurgeApplications() {
            _ = app.forceTerminate()
        }

        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Self.runningSurgeApplications().isEmpty {
                return prepared
            }
        }

        return false
    }

    private func restoreSurgeAfterBlazeIfSafe(stepID: Int) async -> Bool {
        await refreshPacketTunnelStatus(updateStatusText: false)
        guard !packetTunnelConnected else {
            setStartupStep(
                stepID,
                status: .actionNeeded,
                detail: "Blaze VPN is still connected; not restarting Surge to avoid DNS/utun takeover"
            )
            return true
        }

        guard let candidate = surgeRestoreCandidate else {
            await refreshSurgeStatus(updateStatusText: false)
            if surgeAppSnapshot.isRunning {
                setStartupStep(stepID, status: .passed, detail: "Surge is already running")
                return true
            }
            setStartupStep(stepID, status: .info, detail: "No Surge restore candidate was captured")
            return true
        }

        do {
            await refreshSurgeStatus(updateStatusText: false)
            if !surgeAppSnapshot.isRunning {
                try await Self.openSurge(candidate)
            }

            let shouldRestoreVPN = candidate.hasConnectedNetworkTunnel
            var lastVPNStartError: Error?
            for attempt in 0..<16 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if shouldRestoreVPN {
                    do {
                        try await Self.startSurgeVPNServiceIfAvailable()
                    } catch {
                        lastVPNStartError = error
                    }
                }
                await refreshSurgeStatus(updateStatusText: false)
                let surgeVPNConnected = surgeAppSnapshot.hasConnectedNetworkTunnel
                if surgeAppSnapshot.isRunning && (!shouldRestoreVPN || surgeVPNConnected) {
                    let vpnText = shouldRestoreVPN ? "; VPN connected" : ""
                    setStartupStep(stepID, status: .passed, detail: "Restarted Surge: \(surgeAppSnapshot.restoreLabel)\(vpnText)")
                    return true
                }
                if attempt == 4, !surgeAppSnapshot.isRunning {
                    try? await Self.openSurge(candidate)
                }
            }
            let detail = surgeAppSnapshot.isRunning
                ? "Surge app is running but VPN did not reconnect: \(surgeAppSnapshot.networkTunnelStatus)\(lastVPNStartError.map { "; start error: \($0)" } ?? "")"
                : "Requested Surge restart, but no running Surge app was detected"
            setStartupStep(stepID, status: .failed, detail: detail)
            return false
        } catch {
            setStartupStep(stepID, status: .failed, detail: "Surge restart failed: \(error)")
            return false
        }
    }

    func refreshStartupWorkflowStatus() async {
        guard !startupWorkflowRunning else { return }
        await refreshSurgeStatus(updateStatusText: false)
        await refreshSystemProxyStatus(updateStatusText: false)
        await refreshAppTrustStatus(updateStatusText: false)
        await refreshSystemExtensionInstallStatus(updateStatusText: false)
        await refreshPacketTunnelStatus(updateStatusText: false)
        updateStartupWorkflowFromCurrentState()
        statusText = "Startup flow status refreshed"
    }

    func runStartupWorkflow() async {
        guard !startupWorkflowRunning else { return }
        startupWorkflowRunning = true
        startupWorkflowSteps = StartupWorkflowStep.defaults()
        statusText = "Running startup flow..."
        startStartupWatchdog()
        defer {
            if !startupWatchdogShouldRecover {
                stopStartupWatchdog(markCompleted: true)
            } else if let deadline = startupWatchdogDeadline,
                      startupWatchdogText.hasPrefix("Armed") {
                startupWatchdogText = "Safety restore at \(deadline.formatted(date: .omitted, time: .standard))"
            }
            startupWorkflowRunning = false
            statusText = startupWorkflowSubtitle
        }

        for stepID in startupWorkflowSteps.map(\.id) {
            let canContinue = await performStartupWorkflowStep(stepID)
            guard canContinue else {
                markRemainingStartupStepsSkipped(after: stepID, reason: "Skipped because step \(stepID) did not finish successfully")
                if startupWatchdogShouldRecover {
                    await recoverFromStartupWatchdog(reason: "Startup workflow stopped at step \(stepID)")
                }
                return
            }
        }
    }

    func runStartupWorkflowStep(_ stepID: Int) async {
        guard !startupWorkflowRunning else { return }
        startupWorkflowRunning = true
        defer {
            startupWorkflowRunning = false
            statusText = startupWorkflowSubtitle
        }
        _ = await performStartupWorkflowStep(stepID)
    }

    private func startStartupWatchdog(timeoutSeconds: TimeInterval = 300) {
        startupWatchdogTask?.cancel()
        startupWatchdogRecoveryInProgress = false
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        startupWatchdogDeadline = deadline
        startupWatchdogText = "Armed until \(deadline.formatted(date: .omitted, time: .standard))"
        startupWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.checkStartupWatchdog()
            }
        }
    }

    private func stopStartupWatchdog(markCompleted: Bool) {
        startupWatchdogTask?.cancel()
        startupWatchdogTask = nil
        startupWatchdogDeadline = nil
        if markCompleted && startupWatchdogText.hasPrefix("Armed") {
            startupWatchdogText = startupConnectivityPassed ? "Completed" : "Stopped"
        }
    }

    private func checkStartupWatchdog() async {
        guard let deadline = startupWatchdogDeadline,
              Date() >= deadline,
              !startupWatchdogRecoveryInProgress
        else {
            return
        }

        await refreshPacketTunnelStatus(updateStatusText: false)
        await refreshSurgeStatus(updateStatusText: false)
        guard startupWatchdogShouldRecover else {
            startupWatchdogText = "Timed out; no recovery action needed"
            stopStartupWatchdog(markCompleted: false)
            return
        }

        startupWatchdogRecoveryInProgress = true
        await recoverFromStartupWatchdog(reason: "Startup watchdog timed out after 5 minutes")
    }

    private func recoverFromStartupWatchdog(reason: String) async {
        stopStartupWatchdog(markCompleted: false)
        startupWatchdogText = "Recovering: \(reason)"
        await writeStartupWatchdogRecord(reason: reason, phase: "begin")
        setStartupStep(
            7,
            status: .failed,
            detail: "\(reason); stopping Blaze VPN and restoring Surge",
            target: "Watchdog recovery"
        )

        await stopPacketTunnel()
        if !proxyServerRunning && !socksServerRunning {
            statusText = "Blaze listeners were already stopped"
        }
        await refreshPacketTunnelStatus(updateStatusText: false)
        guard !packetTunnelConnected else {
            await writeStartupWatchdogRecord(reason: reason, phase: "blocked-tunnel-still-connected")
            startupWatchdogText = "Recovery blocked: Blaze VPN is still connected"
            statusText = "Startup watchdog could not stop Blaze VPN; leaving app open for manual recovery"
            return
        }
        let restored = await restoreSurgeAfterBlazeIfSafe(stepID: 8)
        await refreshSurgeStatus(updateStatusText: false)
        await writeStartupWatchdogRecord(reason: reason, phase: restored ? "restored" : "restore-failed")
        startupWatchdogText = restored
            ? "Recovered at \(Date().formatted(date: .omitted, time: .standard))"
            : "Recovery incomplete at \(Date().formatted(date: .omitted, time: .standard))"
        statusText = restored
            ? "Startup watchdog recovered network state; Blaze VPN stopped and Surge restore attempted"
            : "Startup watchdog stopped Blaze VPN, but Surge did not return to its previous VPN state"
        scheduleTerminationAfterWatchdogRecovery()
    }

    private func scheduleTerminationAfterWatchdogRecovery() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            NSApp.terminate(nil)
        }
    }

    private func writeStartupWatchdogRecord(reason: String, phase: String) async {
        await refreshAppTrustStatus(updateStatusText: false)
        await refreshSystemExtensionInstallStatus(updateStatusText: false)
        let url = Self.startupWatchdogRecordURL()
        let lines = [
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))",
            "phase=\(phase)",
            "reason=\(reason)",
            "watchdog=\(startupWatchdogText)",
            "appTrust=\(appTrustSnapshot?.detail ?? appTrustText)",
            "systemExtension=\(systemExtensionInstallSnapshot?.detail ?? systemExtensionInstallText)",
            "packetTunnel=\(packetTunnelStatusText)",
            "packetTunnelConfig=\(packetTunnelConfigurationText)",
            "packetTunnelDiagnostics=\(packetTunnelDiagnosticsText)",
            "surge=\(surgeAppSnapshot.summary); \(surgeAppSnapshot.networkTunnelStatus)",
            "connectivityResults=\(connectivityTestResults.count)",
            "blockingFailures=\(Self.blockingConnectivityFailures(in: connectivityTestResults).map { "\($0.name) \($0.transport): \($0.detail)" }.joined(separator: "; "))",
            "criticalProxyFailures=\(recentCriticalProxyFailures.prefix(6).map { "\($0.host):\($0.port) \($0.note)" }.joined(separator: " || "))",
            ""
        ]
        let text = lines.joined(separator: "\n")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            statusText = "Watchdog record write failed: \(error)"
        }
    }

    private func performStartupWorkflowStep(_ stepID: Int) async -> Bool {
        switch stepID {
        case 1:
            setStartupStep(
                stepID,
                status: .running,
                detail: "Detecting Surge and external proxy takeover"
            )
            await refreshSurgeStatus(updateStatusText: false)
            await refreshSystemProxyStatus(updateStatusText: false)

            if surgeAppSnapshot.isRunning || surgeAppSnapshot.hasConnectedNetworkTunnel {
                surgeRestoreCandidate = surgeAppSnapshot
                surgeRestoreText = "Restore candidate: \(surgeAppSnapshot.restoreLabel)"
                let reason = [
                    surgeAppSnapshot.isRunning ? "Surge app is running" : nil,
                    surgeAppSnapshot.hasConnectedNetworkTunnel ? "Surge VPN service is connected" : nil
                ].compactMap(\.self).joined(separator: "; ")
                setStartupStep(
                    stepID,
                    status: .running,
                    detail: "\(reason); stopping it before Blaze VPN starts"
                )
                let closed = await prepareSurgeForBlaze()
                await refreshSurgeStatus(updateStatusText: false)
                if closed && !surgeAppSnapshot.isRunning && !surgeAppSnapshot.hasConnectedNetworkTunnel {
                    setStartupStep(stepID, status: .passed, detail: "Surge app/VPN stopped; \(surgeRestoreText)")
                    return true
                }
                setStartupStep(stepID, status: .failed, detail: "Surge is still active: \(surgeAppSnapshot.summary); \(surgeAppSnapshot.networkTunnelStatus)")
                return false
            }

            if effectiveProxyStatus.anyProxyEnabled && !effectiveProxyStatus.matchesBlaze && !packetTunnelConnected {
                setStartupStep(
                    stepID,
                    status: .actionNeeded,
                    detail: "Surge is not running, but another effective proxy is active: \(effectiveProxyStatus.summary)"
                )
                return true
            }

            setStartupStep(stepID, status: .passed, detail: "No running Surge app detected; \(surgeAppSnapshot.networkTunnelStatus)")
            return true

        case 2:
            setStartupStep(
                stepID,
                status: .running,
                detail: "Checking host entitlement and requesting extension activation"
            )
            await refreshAppTrustStatus(updateStatusText: false)
            if let trust = appTrustSnapshot, !trust.accepted {
                setStartupStep(
                    stepID,
                    status: .failed,
                    detail: "App trust check rejected the installed bundle: \(trust.detail)"
                )
                return false
            }

            guard SystemExtensionController.hostHasInstallEntitlement() else {
                setStartupStep(
                    stepID,
                    status: .failed,
                    detail: "Host app signature is missing \(SystemExtensionController.requiredHostEntitlement); \(appTrustSnapshot?.detail ?? appTrustText)"
                )
                return false
            }

            activatePacketTunnelSystemExtension()
            for _ in 0..<24 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await refreshSystemExtensionInstallStatus(updateStatusText: false)
                let status = packetTunnelStatusText
                if status.localizedCaseInsensitiveContains("failed") || status.localizedCaseInsensitiveContains("missing") {
                    setStartupStep(stepID, status: .failed, detail: "\(status); \(appTrustSnapshot?.detail ?? appTrustText)")
                    return false
                }
                if status.localizedCaseInsensitiveContains("approval") {
                    setStartupStep(stepID, status: .actionNeeded, detail: "\(status); \(systemExtensionInstallSnapshot?.detail ?? systemExtensionInstallText)")
                    return true
                }
                if let snapshot = systemExtensionInstallSnapshot, snapshot.isActiveLatest {
                    setStartupStep(stepID, status: .passed, detail: "\(status); \(snapshot.detail); \(appTrustSnapshot?.summary ?? appTrustText)")
                    return true
                }
            }

            let status = packetTunnelStatusText
            if status.localizedCaseInsensitiveContains("approval") || status.localizedCaseInsensitiveContains("submitting") {
                setStartupStep(stepID, status: .actionNeeded, detail: "\(status); \(systemExtensionInstallText)")
                return true
            }
            setStartupStep(
                stepID,
                status: .failed,
                detail: [
                    systemExtensionInstallSnapshot?.detail ?? "System extension did not become active latest",
                    appTrustSnapshot?.detail ?? appTrustText
                ].joined(separator: "; ")
            )
            return false

        case 3:
            setStartupStep(
                stepID,
                status: .running,
                detail: "Starting local HTTP and SOCKS5 listeners",
                target: "HTTP \(proxyListenPort), SOCKS5 \(socksListenPort)"
            )
            await startLocalProxyStack()
            if proxyServerRunning && socksServerRunning {
                setStartupStep(stepID, status: .passed, detail: localProxySummary)
                return true
            }
            setStartupStep(stepID, status: .failed, detail: statusText)
            return false

        case 4:
            setStartupStep(
                stepID,
                status: .running,
                detail: "Installing Packet Tunnel provider configuration"
            )
            await installPacketTunnelConfiguration()
            if let snapshot = packetTunnelConfigurationSnapshot {
                setStartupStep(
                    stepID,
                    status: .passed,
                    detail: "\(snapshot.engineDescription); \(snapshot.dnsSummary); \(packetTunnelExcludedIPv4Summary)"
                )
                return true
            }
            setStartupStep(stepID, status: .failed, detail: packetTunnelConfigurationText)
            return false

        case 5:
            setStartupStep(
                stepID,
                status: .running,
                detail: "Starting Packet Tunnel Global VPN"
            )
            await startPacketTunnel()
            if packetTunnelConnected {
                setStartupStep(stepID, status: .passed, detail: packetTunnelStatusText)
                return true
            }
            if packetTunnelTransitioning {
                setStartupStep(stepID, status: .actionNeeded, detail: packetTunnelStatusText)
                return false
            }
            setStartupStep(stepID, status: .failed, detail: packetTunnelStatusText)
            return false

        case 6:
            setStartupStep(
                stepID,
                status: .running,
                detail: "Reading tunnel status and packet counters"
            )
            await refreshPacketTunnelStatus(updateStatusText: false)
            guard packetTunnelConnected else {
                setStartupStep(stepID, status: .failed, detail: "Tunnel is not connected: \(packetTunnelStatusText)")
                return false
            }
            if let snapshot = packetTunnelDiagnosticsSnapshot {
                setStartupStep(stepID, status: .passed, detail: snapshot.summary)
                return true
            }
            setStartupStep(stepID, status: .failed, detail: packetTunnelDiagnosticsText)
            return false

        case 7:
            setStartupStep(
                stepID,
                status: .running,
                detail: "Running connectivity diagnostics",
                target: "Diagnostics 0/\(Self.expectedConnectivityResultCount)"
            )
            await runConnectivityDiagnostics()
            let blockingFailures = Self.blockingConnectivityFailures(in: connectivityTestResults)
            let warningFailures = connectivityTestResults.filter { $0.status == .failed && !$0.isBlockingStartupFailure }
            if blockingFailures.isEmpty && !connectivityTestResults.isEmpty {
                let warningText = warningFailures.isEmpty ? "" : "; \(warningFailures.count) warning\(warningFailures.count == 1 ? "" : "s")"
                setStartupStep(
                    stepID,
                    status: .passed,
                    detail: "\(connectivityTestResults.count) checks completed\(warningText)",
                    target: "Diagnostics \(connectivityTestResults.count)/\(Self.expectedConnectivityResultCount)"
                )
                return true
            }
            let failedNames = blockingFailures.prefix(4).map { "\($0.name) \($0.transport)" }.joined(separator: ", ")
            let suffix = blockingFailures.count > 4 ? ", +\(blockingFailures.count - 4) more" : ""
            setStartupStep(
                stepID,
                status: .failed,
                detail: blockingFailures.isEmpty ? "No connectivity results were produced" : "Blocking failures: \(failedNames)\(suffix)",
                target: "Diagnostics \(connectivityTestResults.count)/\(Self.expectedConnectivityResultCount)"
            )
            return false

        case 8:
            setStartupStep(
                stepID,
                status: .running,
                detail: "Checking whether Surge should be restored"
            )
            return await restoreSurgeAfterBlazeIfSafe(stepID: stepID)

        default:
            return false
        }
    }

    private func updateStartupWorkflowFromCurrentState() {
        let surgeStatus: StartupWorkflowStepStatus
        let surgeDetail: String
        if surgeAppSnapshot.isRunning {
            surgeStatus = .actionNeeded
            surgeDetail = "Surge is running and can take over DNS/utun before Blaze VPN starts"
        } else if effectiveProxyStatus.anyProxyEnabled && !effectiveProxyStatus.matchesBlaze && !packetTunnelConnected {
            surgeStatus = .actionNeeded
            surgeDetail = "Another effective proxy is active: \(effectiveProxyStatus.summary)"
        } else if surgeAppSnapshot.hasConnectedNetworkTunnel {
            surgeStatus = .actionNeeded
            surgeDetail = surgeAppSnapshot.networkTunnelStatus
        } else {
            surgeStatus = .passed
            surgeDetail = "No running Surge app detected; \(surgeAppSnapshot.networkTunnelStatus)"
        }
        setStartupStep(1, status: surgeStatus, detail: surgeDetail, target: surgeAppSnapshot.summary)

        let extensionLatest = systemExtensionInstallSnapshot?.isActiveLatest ?? false
        let appTrustAccepted = appTrustSnapshot?.accepted ?? false
        let extensionStatus: StartupWorkflowStepStatus = SystemExtensionController.hostHasInstallEntitlement() && extensionLatest && appTrustAccepted ? .passed : .failed
        setStartupStep(
            2,
            status: extensionStatus,
            detail: "\(SystemExtensionController.hostEntitlementStatusText); \(systemExtensionInstallSnapshot?.detail ?? systemExtensionInstallText); \(appTrustSnapshot?.detail ?? appTrustText)"
        )

        let listenerStatus: StartupWorkflowStepStatus
        let listenerDetail: String
        if proxyServerRunning && socksServerRunning {
            listenerStatus = .passed
            listenerDetail = localProxySummary
        } else if proxyServerRunning || socksServerRunning {
            listenerStatus = .failed
            listenerDetail = "Partial listener state: \(localProxySummary)"
        } else {
            listenerStatus = .pending
            listenerDetail = "Local listeners are stopped"
        }
        setStartupStep(
            3,
            status: listenerStatus,
            detail: listenerDetail,
            target: "HTTP \(proxyListenPort), SOCKS5 \(socksListenPort)"
        )

        setStartupStep(
            4,
            status: packetTunnelConfigurationSnapshot == nil ? .pending : .passed,
            detail: packetTunnelConfigurationText
        )

        let tunnelStatus: StartupWorkflowStepStatus
        if packetTunnelConnected {
            tunnelStatus = .passed
        } else if packetTunnelTransitioning {
            tunnelStatus = .actionNeeded
        } else if packetTunnelStatusText.localizedCaseInsensitiveContains("failed") {
            tunnelStatus = .failed
        } else {
            tunnelStatus = .pending
        }
        setStartupStep(5, status: tunnelStatus, detail: packetTunnelStatusText)

        let diagnosticsStatus: StartupWorkflowStepStatus
        if packetTunnelDiagnosticsSnapshot != nil {
            diagnosticsStatus = .passed
        } else if packetTunnelConnected {
            diagnosticsStatus = .pending
        } else {
            diagnosticsStatus = .pending
        }
        setStartupStep(6, status: diagnosticsStatus, detail: packetTunnelDiagnosticsText)

        let testFailures = Self.blockingConnectivityFailures(in: connectivityTestResults)
        let warningFailures = connectivityTestResults.filter { $0.status == .failed && !$0.isBlockingStartupFailure }
        if connectivityTestResults.isEmpty {
            setStartupStep(7, status: .pending, detail: "Not run")
        } else if testFailures.isEmpty {
            let warningText = warningFailures.isEmpty ? "" : "; \(warningFailures.count) warning\(warningFailures.count == 1 ? "" : "s")"
            setStartupStep(7, status: .passed, detail: "\(connectivityTestResults.count) checks completed\(warningText)")
        } else {
            setStartupStep(7, status: .failed, detail: "\(testFailures.count) blocking checks failed")
        }

        if surgeRestoreCandidate == nil {
            setStartupStep(8, status: .info, detail: surgeRestoreText)
        } else if packetTunnelConnected {
            setStartupStep(8, status: .actionNeeded, detail: "Surge restore is held until Blaze VPN is stopped")
        } else if surgeAppSnapshot.isRunning {
            setStartupStep(8, status: .passed, detail: "Surge is running")
        } else {
            setStartupStep(8, status: .pending, detail: surgeRestoreText)
        }
    }

    private func markRemainingStartupStepsSkipped(after failedStepID: Int, reason: String) {
        for step in startupWorkflowSteps where step.id > failedStepID && step.status == .pending {
            setStartupStep(step.id, status: .info, detail: reason)
        }
    }

    private func setStartupStep(
        _ stepID: Int,
        status: StartupWorkflowStepStatus,
        detail: String,
        target: String? = nil
    ) {
        guard let index = startupWorkflowSteps.firstIndex(where: { $0.id == stepID }) else { return }
        let previousStatus = startupWorkflowSteps[index].status
        let previousDetail = startupWorkflowSteps[index].detail
        startupWorkflowSteps[index].status = status
        startupWorkflowSteps[index].detail = detail
        startupWorkflowSteps[index].updatedAt = Date()
        if let target {
            startupWorkflowSteps[index].target = target
        }
        let detailChanged = previousDetail != detail
        let shouldLog: Bool
        switch status {
        case .pending, .info:
            shouldLog = false
        case .running:
            // Log when the step first enters running, and on each significant
            // detail change while running (so Step 7's probe-by-probe progress
            // reaches proxy-events.log).
            shouldLog = previousStatus != status || detailChanged
        case .passed, .actionNeeded:
            shouldLog = previousStatus != status
        case .failed:
            shouldLog = previousStatus != status || detailChanged
        }
        if shouldLog {
            recordStartupStepEvent(
                step: stepID,
                status: status,
                detail: detail,
                target: target ?? startupWorkflowSteps[index].target
            )
        }
    }

    private func recordStartupStepEvent(
        step: Int,
        status: StartupWorkflowStepStatus,
        detail: String,
        target: String?
    ) {
        let logStatus: String
        switch status {
        case .pending, .info:
            return
        case .running:
            logStatus = "Info"
        case .passed:
            logStatus = "Passed"
        case .failed:
            logStatus = "Failed"
        case .actionNeeded:
            logStatus = "Info"
        }
        let note: String
        if let target, !target.isEmpty {
            note = "Step \(step) \(status.rawValue): \(detail) [\(target)]"
        } else {
            note = "Step \(step) \(status.rawValue): \(detail)"
        }
        let event = ProxyServerEvent(
            method: "STARTUP",
            target: "step-\(step)",
            host: "blaze",
            port: 0,
            policy: "Startup Workflow",
            status: logStatus,
            rule: "Workflow",
            note: note
        )
        Task {
            await proxyLogStore.append(event)
            await refreshProxyEvents()
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
            await refreshPacketTunnelConfiguration(updateStatusText: false)
            let snapshot = try await PacketTunnelConfigurationManager.statusSnapshot()
            packetTunnelStatusText = snapshot.text
            packetTunnelConnected = snapshot.isConnected
            packetTunnelTransitioning = snapshot.isTransitioning
            if snapshot.isConnected {
                await refreshPacketTunnelDiagnostics(updateStatusText: false)
            } else {
                packetTunnelDiagnosticsText = "Tunnel is not connected"
                packetTunnelDiagnosticsSnapshot = nil
            }
            if updateStatusText {
                statusText = "Packet tunnel status: \(snapshot.text)"
            }
        } catch {
            packetTunnelStatusText = "Not configured"
            packetTunnelConnected = false
            packetTunnelTransitioning = false
            packetTunnelDiagnosticsText = "Unavailable"
            packetTunnelDiagnosticsSnapshot = nil
            packetTunnelConfigurationSnapshot = nil
            packetTunnelConfigurationText = "Unavailable"
            if updateStatusText {
                statusText = "Packet tunnel status unavailable: \(error)"
            }
        }
    }

    func refreshPacketTunnelConfiguration() async {
        await refreshPacketTunnelConfiguration(updateStatusText: true)
    }

    private func refreshPacketTunnelConfiguration(updateStatusText: Bool) async {
        do {
            let snapshot = try await PacketTunnelConfigurationManager.configurationSnapshot()
            packetTunnelConfigurationSnapshot = snapshot
            packetTunnelConfigurationText = "\(snapshot.engineDescription); MTU \(snapshot.tunnelMTU); DNS \(snapshot.tunnelDNSServers.joined(separator: ", ")); \(snapshot.listenerSummary)"
            if updateStatusText {
                statusText = "Packet tunnel config: \(packetTunnelConfigurationText)"
            }
        } catch {
            packetTunnelConfigurationSnapshot = nil
            packetTunnelConfigurationText = "Unavailable: \(error)"
            if updateStatusText {
                statusText = "Packet tunnel config unavailable: \(error)"
            }
        }
    }

    func refreshPacketTunnelDiagnostics() async {
        await refreshPacketTunnelDiagnostics(updateStatusText: true)
    }

    private func refreshPacketTunnelDiagnostics(updateStatusText: Bool) async {
        do {
            let snapshot = try await PacketTunnelConfigurationManager.diagnosticsSnapshot()
            packetTunnelDiagnosticsSnapshot = snapshot
            packetTunnelDiagnosticsText = snapshot.summary
            packetTunnelLastDiagnosticsRefreshText = Date().formatted(date: .omitted, time: .standard)
            if updateStatusText {
                statusText = "Packet tunnel diagnostics: \(snapshot.summary)"
            }
        } catch {
            packetTunnelDiagnosticsSnapshot = nil
            packetTunnelDiagnosticsText = "Unavailable: \(error)"
            if updateStatusText {
                statusText = "Packet tunnel diagnostics unavailable: \(error)"
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

    func handleAutomationURL(_ url: URL) {
        guard url.scheme == "blaze", url.host == "control" else { return }
        let action = url.pathComponents.dropFirst().first ?? ""
        recordAutomationEvent(action: action, url: url)

        switch action {
        case "start-listeners":
            Task { await startLocalProxyStack() }
        case "stop-listeners":
            Task {
                await stopLocalProxyServer()
                await stopLocalSocksServer()
            }
        case "start-tunnel":
            Task { await startPacketTunnel() }
        case "stop-tunnel":
            Task { await stopPacketTunnel() }
        case "refresh-tunnel":
            Task { await refreshPacketTunnelStatus() }
        case "run-startup-workflow":
            Task { await runStartupWorkflow() }
        case "recover-startup":
            Task { await runStartupWatchdogRecoveryNow(reason: "Automation recovery requested") }
        default:
            statusText = "Unknown automation URL action: \(action)"
        }
    }

    private func recordAutomationEvent(action: String, url: URL) {
        let event = ProxyServerEvent(
            method: "AUTO",
            target: url.absoluteString,
            host: "blaze",
            port: 0,
            policy: "Automation",
            status: "Info",
            rule: "Control",
            note: "Received automation action: \(action.isEmpty ? "<empty>" : action)"
        )
        Task {
            await proxyLogStore.append(event)
            await refreshProxyEvents()
        }
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

    private static func runningSurgeApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            let name = app.localizedName?.lowercased() ?? ""
            let bundleIdentifier = app.bundleIdentifier?.lowercased() ?? ""
            return name == "surge"
                || name.hasPrefix("surge ")
                || bundleIdentifier.contains("surge")
                || bundleIdentifier.contains("nssurge")
        }
    }

    private static func detectSurgeApp() -> SurgeAppSnapshot {
        guard let app = runningSurgeApplications().first else {
            return SurgeAppSnapshot.notRunning
        }

        return SurgeAppSnapshot(
            isRunning: true,
            appName: app.localizedName ?? "Surge",
            bundleIdentifier: app.bundleIdentifier,
            bundlePath: app.bundleURL?.path,
            processIdentifier: app.processIdentifier,
            networkTunnelStatus: "Not checked"
        )
    }

    private nonisolated static func systemExtensionInstallSnapshot() async -> SystemExtensionInstallSnapshot {
        let host = bundleVersionInfo(at: Bundle.main.bundleURL)
        let bundled = bundleVersionInfo(at: bundledSystemExtensionURL())
        let output = (try? await systemExtensionsListOutput()) ?? ""
        let statusLine = activeSystemExtensionLine(from: output)
        let active = statusLine.flatMap(versionBuild(from:))

        return SystemExtensionInstallSnapshot(
            hostVersion: host.version,
            hostBuild: host.build,
            bundledVersion: bundled.version,
            bundledBuild: bundled.build,
            activeVersion: active?.version,
            activeBuild: active?.build,
            statusLine: statusLine ?? "No active \(SystemExtensionController.extensionIdentifier) entry in systemextensionsctl list"
        )
    }

    private nonisolated static func appTrustSnapshot() async -> AppTrustSnapshot {
        let host = bundleVersionInfo(at: Bundle.main.bundleURL)
        let result = await commandOutputResult(
            executablePath: "/usr/sbin/spctl",
            arguments: [
                "--assess",
                "--type",
                "execute",
                "--verbose=4",
                Bundle.main.bundleURL.path
            ]
        )
        let lines = result.combinedText
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let statusLine = lines.first ?? "spctl produced no output"
        return AppTrustSnapshot(
            hostVersion: host.version,
            hostBuild: host.build,
            accepted: result.exitCode == 0,
            exitCode: result.exitCode,
            statusLine: statusLine,
            sourceLine: lines.first { $0.hasPrefix("source=") },
            originLine: lines.first { $0.hasPrefix("origin=") }
        )
    }

    private nonisolated static func bundledSystemExtensionURL() -> URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("SystemExtensions", isDirectory: true)
            .appendingPathComponent("\(SystemExtensionController.extensionIdentifier).systemextension", isDirectory: true)
    }

    private nonisolated static func bundleVersionInfo(at bundleURL: URL) -> (version: String, build: String) {
        let infoURL = bundleURL.appendingPathComponent("Contents", isDirectory: true).appendingPathComponent("Info.plist")
        let dictionary = NSDictionary(contentsOf: infoURL) as? [String: Any]
        let bundle = Bundle(url: bundleURL)
        let version = dictionary?["CFBundleShortVersionString"] as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
        let build = dictionary?["CFBundleVersion"] as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "unknown"
        return (version, build)
    }

    private nonisolated static func activeSystemExtensionLine(from output: String) -> String? {
        let lines = output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.contains(SystemExtensionController.extensionIdentifier) }
        return lines.first {
            $0.contains("[activated enabled]") && !$0.localizedCaseInsensitiveContains("terminated")
        } ?? lines.first {
            $0.contains("[activated")
        } ?? lines.first
    }

    private nonisolated static func versionBuild(from line: String) -> (version: String, build: String)? {
        guard let open = line.firstIndex(of: "("),
              let close = line[open...].firstIndex(of: ")")
        else {
            return nil
        }
        let pair = line[line.index(after: open)..<close].split(separator: "/", maxSplits: 1).map(String.init)
        guard pair.count == 2 else { return nil }
        return (pair[0], pair[1])
    }

    private nonisolated static func commandOutputResult(executablePath: String, arguments: [String]) async -> CommandOutputResult {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
                process.waitUntilExit()
                let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
                return CommandOutputResult(
                    exitCode: process.terminationStatus,
                    output: String(data: output, encoding: .utf8) ?? "",
                    errorOutput: String(data: errorOutput, encoding: .utf8) ?? ""
                )
            } catch {
                return CommandOutputResult(
                    exitCode: -1,
                    output: "",
                    errorOutput: "\(executablePath) failed to run: \(error)"
                )
            }
        }.value
    }

    private nonisolated static func systemExtensionsListOutput() async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/systemextensionsctl")
            process.arguments = ["list"]

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
                throw NetworkServiceDetectionError.commandFailed(message?.isEmpty == false ? message! : "systemextensionsctl exited with \(process.terminationStatus)")
            }
            return String(data: output, encoding: .utf8) ?? ""
        }.value
    }

    private nonisolated static func surgeNetworkTunnelStatus() async throws -> String {
        let text = try await scutilNetworkConnectionListOutput()
        let surgeLines = text
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.localizedCaseInsensitiveContains("surge") }

        guard !surgeLines.isEmpty else {
            return "No Surge VPN service listed"
        }
        if surgeLines.contains(where: { vpnServiceState(in: $0) == "Connected" }) {
            return "Surge VPN service is connected"
        }
        return "Surge VPN service listed but not connected"
    }

    private nonisolated static func vpnServiceState(in line: String) -> String? {
        guard let open = line.firstIndex(of: "("),
              let close = line[open...].firstIndex(of: ")"),
              open < close
        else {
            return nil
        }
        return String(line[line.index(after: open)..<close])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func startSurgeVPNServiceIfAvailable() async throws {
        let text = try await scutilNetworkConnectionListOutput()
        guard let serviceIdentifier = surgeVPNServiceIdentifier(from: text) else {
            throw NetworkServiceDetectionError.commandFailed("No Surge VPN service identifier found")
        }
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
            process.arguments = ["--nc", "start", serviceIdentifier]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let message = [String(data: output, encoding: .utf8), String(data: errorOutput, encoding: .utf8)]
                    .compactMap { value -> String? in
                        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        return trimmed.isEmpty ? nil : trimmed
                    }
                    .joined(separator: " ")
                throw NetworkServiceDetectionError.commandFailed(message.isEmpty ? "scutil --nc start exited with \(process.terminationStatus)" : message)
            }
        }.value
    }

    private nonisolated static func stopSurgeVPNServiceIfAvailable() async throws {
        let text = try await scutilNetworkConnectionListOutput()
        guard let serviceIdentifier = surgeVPNServiceIdentifier(from: text) else {
            throw NetworkServiceDetectionError.commandFailed("No Surge VPN service identifier found")
        }
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
            process.arguments = ["--nc", "stop", serviceIdentifier]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let message = [String(data: output, encoding: .utf8), String(data: errorOutput, encoding: .utf8)]
                    .compactMap { value -> String? in
                        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        return trimmed.isEmpty ? nil : trimmed
                    }
                    .joined(separator: " ")
                throw NetworkServiceDetectionError.commandFailed(message.isEmpty ? "scutil --nc stop exited with \(process.terminationStatus)" : message)
            }
        }.value
    }

    private nonisolated static func surgeVPNServiceIdentifier(from text: String) -> String? {
        let pattern = #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for line in text.split(separator: "\n").map(String.init) where line.localizedCaseInsensitiveContains("surge") {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = regex.firstMatch(in: line, range: range),
               let matchRange = Range(match.range, in: line) {
                return String(line[matchRange])
            }
        }
        return nil
    }

    private nonisolated static func scutilNetworkConnectionListOutput() async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
            process.arguments = ["--nc", "list"]

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
                throw NetworkServiceDetectionError.commandFailed(message?.isEmpty == false ? message! : "scutil --nc list exited with \(process.terminationStatus)")
            }

            return String(data: output, encoding: .utf8) ?? ""
        }.value
    }

    private nonisolated static func openSurge(_ candidate: SurgeAppSnapshot) async throws {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            if let bundleIdentifier = candidate.bundleIdentifier, !bundleIdentifier.isEmpty {
                process.arguments = ["-b", bundleIdentifier]
            } else if let bundlePath = candidate.bundlePath, !bundlePath.isEmpty {
                process.arguments = [bundlePath]
            } else {
                process.arguments = ["-a", candidate.appName.isEmpty ? "Surge" : candidate.appName]
            }

            let errorPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
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
        await refreshSurgeStatus(updateStatusText: false)
        await refreshPacketTunnelStatus(updateStatusText: false)

        await appendPolicyDiagnostics()

        await appendConnectivityResult(
            ConnectivityTestResult(
                name: "Configured Proxy",
                transport: "networksetup",
                target: networkServiceName,
                status: packetTunnelConnected ? .info : (systemProxyStatus.activation == .active ? .passed : .failed),
                detail: packetTunnelConnected ? "Packet Tunnel is active; macOS proxy settings are not required" : systemProxyStatus.summary,
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
        await appendConnectivityResult(
            ConnectivityTestResult(
                name: "Surge State",
                transport: "External Proxy",
                target: surgeAppSnapshot.restoreLabel,
                status: surgeConflictTestStatus,
                detail: surgeConflictTestDetail,
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

        await runTargetConnectivityProbes()

        let blockingFailures = Self.blockingConnectivityFailures(in: connectivityTestResults).count
        let warnings = connectivityTestResults.filter { $0.status == .failed && !$0.isBlockingStartupFailure }.count
        if blockingFailures == 0 {
            statusText = warnings == 0 ? "Connectivity diagnostics passed" : "Connectivity diagnostics passed with \(warnings) warning\(warnings == 1 ? "" : "s")"
        } else {
            statusText = "Connectivity diagnostics found \(blockingFailures) blocking issue\(blockingFailures == 1 ? "" : "s")"
        }
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
            modeStatus = .passed
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

    // Both startLocalProxyServer / startLocalSocksServer now delegate to leaf,
    // which serves HTTP and SOCKS5 in one process. The Swift LocalHTTPProxyServer
    // and LocalSOCKS5ProxyServer are retained as dependencies but no longer
    // instantiated — they will be removed once all callers migrate.
    func startLocalProxyServer() async {
        await ensureLeafRunning()
    }

    func stopLocalProxyServer() async {
        await ensureLeafStopped(reason: "HTTP proxy stop requested")
    }

    func startLocalSocksServer() async {
        await ensureLeafRunning()
    }

    func stopLocalSocksServer() async {
        await ensureLeafStopped(reason: "SOCKS5 proxy stop requested")
    }

    private func ensureLeafRunning() async {
        let configuration = buildLeafConfiguration()
        let alreadyRunning = await leafController.isRunning
        if alreadyRunning, let current = await leafController.configuration, current == configuration {
            // Nothing to do; leaf is already serving the requested config.
            if !proxyServerRunning { proxyServerRunning = true }
            if !socksServerRunning { socksServerRunning = true }
            return
        }
        saveLocalState()
        if alreadyRunning {
            await leafController.stop()
        }
        do {
            try await leafController.start(with: configuration)
            proxyServerRunning = true
            socksServerRunning = true
            statusText = "Leaf proxy listening on 127.0.0.1:\(proxyListenPort)/\(socksListenPort) (final=\(configuration.defaultProxy))"
            startProxyEventRefresh()
        } catch {
            proxyServerRunning = false
            socksServerRunning = false
            statusText = "Leaf launch failed: \(error.localizedDescription)"
        }
    }

    private func ensureLeafStopped(reason: String) async {
        await leafController.stop()
        proxyServerRunning = false
        socksServerRunning = false
        proxyServer = nil
        socksServer = nil
        await refreshProxyEvents()
        statusText = "Leaf proxy stopped (\(reason))"
        proxyRefreshTask?.cancel()
        proxyRefreshTask = nil
    }

    private func buildLeafConfiguration() -> LeafConfiguration {
        var proxies: [LeafConfiguration.Proxy] = [
            .init(tag: "DIRECT", protocolName: "direct"),
            .init(tag: "REJECT", protocolName: "drop")
        ]
        var seenTags: Set<String> = ["DIRECT", "REJECT"]
        for node in profile.proxies {
            guard !seenTags.contains(node.name) else { continue }
            guard let mapped = leafProxy(from: node) else { continue }
            seenTags.insert(node.name)
            proxies.append(mapped)
        }

        let finalPolicy = effectiveLeafFinalPolicy(in: seenTags)
        let rules: [LeafConfiguration.Rule] = [.final(finalPolicy)]

        return LeafConfiguration(
            httpPort: proxyListenPort,
            socksPort: socksListenPort,
            dnsServers: ["1.1.1.1", "119.29.29.29", "223.5.5.5", "8.8.8.8"],
            boundInterface: WorkbenchStore.physicalInterfaceName(),
            logLevel: "info",
            proxies: proxies,
            rules: rules,
            defaultProxy: finalPolicy
        )
    }

    private func effectiveLeafFinalPolicy(in availableTags: Set<String>) -> String {
        // Prefer the user-selected global proxy when it maps to a leaf proxy
        // we successfully emitted. Otherwise fall back to the first usable
        // trojan/shadowsocks node we know about, and finally DIRECT.
        switch proxyRoutingMode {
        case .direct:
            return "DIRECT"
        case .global, .ruleBased:
            if availableTags.contains(globalProxyPolicy) {
                return globalProxyPolicy
            }
            if let selected = selectedPolicies[globalProxyPolicy],
               availableTags.contains(selected) {
                return selected
            }
            if let firstNode = profile.proxies.first(where: {
                ($0.kind == .trojan || $0.kind == .shadowsocks || $0.kind == .socks5)
                && availableTags.contains($0.name)
            }) {
                return firstNode.name
            }
            return "DIRECT"
        }
    }

    private func leafProxy(from node: ProxyNode) -> LeafConfiguration.Proxy? {
        let p = node.parameters
        func bool(_ key: String) -> Bool {
            guard let value = p[key]?.lowercased() else { return false }
            return ["1", "true", "yes", "on"].contains(value)
        }
        switch node.kind {
        case .direct:
            return .init(tag: node.name, protocolName: "direct")
        case .reject:
            return .init(tag: node.name, protocolName: "drop")
        case .trojan:
            return .init(
                tag: node.name,
                protocolName: "trojan",
                address: node.host,
                port: node.port,
                password: node.password,
                sni: p["sni"] ?? p["server-name"],
                tlsInsecure: bool("skip-cert-verify") || bool("allow-insecure"),
                ws: bool("ws"),
                wsPath: p["ws-path"],
                wsHost: p["ws-host"]
            )
        case .shadowsocks:
            return .init(
                tag: node.name,
                protocolName: "shadowsocks",
                address: node.host,
                port: node.port,
                password: node.password,
                encryptMethod: p["encrypt-method"] ?? p["method"]
            )
        case .socks5:
            return .init(tag: node.name, protocolName: "socks", address: node.host, port: node.port)
        default:
            return nil
        }
    }

    private static func physicalInterfaceName() -> String? {
        // Pick the first up, non-loopback IPv4 interface whose name starts
        // with "en" (Wi-Fi or wired ethernet). This is what we want leaf to
        // bind its outbound connections to so it bypasses any utun the
        // packet tunnel sets up.
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(first) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = current {
            defer { current = pointer.pointee.ifa_next }
            guard let address = pointer.pointee.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_INET else { continue }
            let flags = pointer.pointee.ifa_flags
            guard (flags & UInt32(IFF_UP)) != 0,
                  (flags & UInt32(IFF_RUNNING)) != 0,
                  (flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: pointer.pointee.ifa_name)
            if name.hasPrefix("en") { return name }
        }
        return nil
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
        updateStartupConnectivityProgress(latest: result)
    }

    private func runTargetConnectivityProbes() async {
        let targets = ConnectivityTarget.defaultTargets
        let httpPort = proxyListenPort
        let socksPort = socksListenPort

        await withTaskGroup(of: ConnectivityTestResult.self) { group in
            for target in targets {
                group.addTask {
                    await ConnectivityCurlFetchProbe.fetch(
                        target: target,
                        transport: "HTTP Fetch",
                        proxy: .http(port: httpPort)
                    )
                }
                group.addTask {
                    await ConnectivitySocketProbe.httpConnect(
                        target: target,
                        proxyPort: httpPort
                    )
                }
                group.addTask {
                    await ConnectivitySocketProbe.socks5Connect(
                        target: target,
                        proxyPort: socksPort
                    )
                }
                group.addTask {
                    await ConnectivityCurlFetchProbe.fetch(
                        target: target,
                        transport: "SOCKS5 Fetch",
                        proxy: .socks5(port: socksPort)
                    )
                }
            }

            for await result in group {
                await appendConnectivityResult(result)
            }
        }
    }

    private func updateStartupConnectivityProgress(latest result: ConnectivityTestResult) {
        guard startupWorkflowRunning,
              startupWorkflowSteps.first(where: { $0.id == 7 })?.status == .running
        else {
            return
        }

        let completed = connectivityTestResults.count
        let blockingFailures = Self.blockingConnectivityFailures(in: connectivityTestResults).count
        let warningFailures = connectivityTestResults.filter { $0.status == .failed && !$0.isBlockingStartupFailure }.count
        let failureText: String
        if blockingFailures > 0 {
            failureText = "\(blockingFailures) blocking failure\(blockingFailures == 1 ? "" : "s")"
        } else if warningFailures > 0 {
            failureText = "\(warningFailures) warning\(warningFailures == 1 ? "" : "s")"
        } else {
            failureText = "no failures"
        }

        setStartupStep(
            7,
            status: .running,
            detail: "\(completed)/\(Self.expectedConnectivityResultCount) checks; \(failureText); latest \(result.name) \(result.transport): \(result.status.rawValue)",
            target: "Diagnostics \(completed)/\(Self.expectedConnectivityResultCount)"
        )
    }

    private static var expectedConnectivityResultCount: Int {
        13 + ConnectivityTarget.defaultTargets.count * 4
    }

    private static func blockingConnectivityFailures(in results: [ConnectivityTestResult]) -> [ConnectivityTestResult] {
        results.filter(\.isBlockingStartupFailure)
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

    private nonisolated static func startupWatchdogRecordURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("blaze", isDirectory: true)
            .appendingPathComponent("startup-watchdog-recovery.txt", isDirectory: false)
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
    var fetchMethod = "HEAD"

    static let defaultTargets: [ConnectivityTarget] = [
        ConnectivityTarget(name: "Google", url: URL(string: "https://www.google.com/generate_204")!, expectedStatus: 204...204),
        ConnectivityTarget(name: "Baidu", url: URL(string: "https://www.baidu.com/")!, expectedStatus: 200...399),
        ConnectivityTarget(name: "ChatGPT", url: URL(string: "https://chatgpt.com/")!, expectedStatus: 200...499)
    ]
}

// Probes do blocking syscalls (recv/send/Process.waitUntilExit) for up to
// 20-35s. Running those on Swift's cooperative concurrency pool starves the
// pool: with 12 concurrent probes blocked, every other Task.detached for
// LocalSOCKS5ProxyServer.handleClient (which also uses blocking I/O) has to
// wait for a free thread. That manifested as Build 49-51 Step 7 failures
// where probes timed out at 18s and the same destinations connected
// successfully 30-40s later, once the probes released their threads. Bridge
// blocking work onto a dedicated DispatchQueue, which has a much larger
// thread pool dedicated to exactly this use case.
private enum ConnectivityBlockingDispatcher {
    private static let logger = Logger(subsystem: "com.chenhuazhao.blaze", category: "ConnectivityDispatcher")

    static func run<T: Sendable>(label: String, _ work: @escaping @Sendable () -> T) async -> T {
        logger.notice("[\(label, privacy: .public)] dispatch")
        return await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            // Build 53 showed a private DispatchQueue submitted 12 work blocks
            // simultaneously but none ever executed. Switching to the system
            // global queue (which guarantees a real OS-managed pool with many
            // ready threads) eliminates the "queue was real but empty" hazard.
            DispatchQueue.global(qos: .userInitiated).async {
                logger.notice("[\(label, privacy: .public)] work start")
                let result = work()
                logger.notice("[\(label, privacy: .public)] work done")
                continuation.resume(returning: result)
            }
        }
    }
}

private enum ConnectivityCurlFetchProbe {
    enum ProxyKind: Sendable {
        case http(port: Int)
        case socks5(port: Int)

        var arguments: [String] {
            switch self {
            case .http(let port):
                ["--proxy", "http://127.0.0.1:\(port)"]
            case .socks5(let port):
                ["--socks5-hostname", "127.0.0.1:\(port)"]
            }
        }
    }

    static func fetch(target: ConnectivityTarget, transport: String, proxy: ProxyKind) async -> ConnectivityTestResult {
        let host = target.url.host ?? target.url.absoluteString
        let label = "\(transport):\(host)"
        return await ConnectivityBlockingDispatcher.run(label: label) {
            let start = Date()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")

            var arguments = [
                "--silent",
                "--show-error",
                "--output", "/dev/null",
                "--write-out", "%{http_code}",
                "--connect-timeout", "20",
                "--max-time", "35",
                "--http1.1",
                "--user-agent", "blaze-connectivity-test",
                "--header", "Accept: */*"
            ]
            arguments.append(contentsOf: proxy.arguments)
            if target.fetchMethod.uppercased() == "HEAD" {
                arguments.append("--head")
            } else {
                arguments.append(contentsOf: ["--request", target.fetchMethod])
            }
            arguments.append(target.url.absoluteString)
            process.arguments = arguments

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                return ConnectivityTestResult(
                    name: target.name,
                    transport: transport,
                    target: target.url.host ?? target.url.absoluteString,
                    status: .failed,
                    detail: "curl launch failed: \(error)",
                    durationMilliseconds: elapsed
                )
            }
            process.waitUntilExit()

            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let code = Int(output.suffix(3)) ?? 0
            guard process.terminationStatus == 0 else {
                let detail = [errorOutput, output.isEmpty ? nil : "http_code=\(output)"]
                    .compactMap { value -> String? in
                        guard let value, !value.isEmpty else { return nil }
                        return value
                    }
                    .joined(separator: "; ")
                return ConnectivityTestResult(
                    name: target.name,
                    transport: transport,
                    target: target.url.host ?? target.url.absoluteString,
                    status: .failed,
                    detail: detail.isEmpty ? "curl exited with \(process.terminationStatus)" : "curl exited with \(process.terminationStatus): \(detail)",
                    durationMilliseconds: elapsed
                )
            }
            return ConnectivityTestResult(
                name: target.name,
                transport: transport,
                target: target.url.host ?? target.url.absoluteString,
                status: target.expectedStatus.contains(code) ? .passed : .failed,
                detail: "curl fetch returned \(code)",
                durationMilliseconds: elapsed
            )
        }
    }
}

private enum ConnectivitySocketProbe {
    static func httpConnect(target: ConnectivityTarget, proxyPort: Int) async -> ConnectivityTestResult {
        let host = target.url.host ?? target.url.absoluteString
        return await ConnectivityBlockingDispatcher.run(label: "HTTP CONNECT:\(host)") {
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
        }
    }

    static func socks5Connect(target: ConnectivityTarget, proxyPort: Int) async -> ConnectivityTestResult {
        let host = target.url.host ?? target.url.absoluteString
        return await ConnectivityBlockingDispatcher.run(label: "SOCKS5 CONNECT:\(host)") {
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
        }
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
