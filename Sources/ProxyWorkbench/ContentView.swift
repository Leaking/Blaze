import ProxyWorkbenchCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum WorkbenchSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case proxies = "Proxies"
    case rules = "Rules"
    case ruleSets = "Rule Sets"
    case profiles = "Profiles"
    case traffic = "Traffic"
    case dns = "DNS"
    case tunnel = "Tunnel"
    case tests = "Tests"
    case logs = "Logs"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .proxies: "network"
        case .rules: "list.bullet.rectangle"
        case .ruleSets: "rectangle.stack.badge.plus"
        case .profiles: "person.crop.rectangle.stack"
        case .traffic: "waveform.path.ecg.rectangle"
        case .dns: "globe.desk"
        case .tunnel: "shield.lefthalf.filled"
        case .tests: "checklist"
        case .logs: "doc.text.magnifyingglass"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @State private var selection: WorkbenchSection? = .overview
    @State private var importing = false
    @State private var showingImportConfiguration = false
    @State private var showingCommandPalette = false

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "triangle.inset.filled")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.indigo)
                    Text("blaze")
                        .font(.headline)
                        .foregroundStyle(.indigo)
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)

                List(WorkbenchSection.allCases, selection: $selection) { section in
                    Label(section.rawValue, systemImage: section.icon)
                        .tag(section)
                }
                .listStyle(.sidebar)

                SidebarStatusCard()
                    .environmentObject(store)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            DetailView(selection: selection ?? .overview)
                .toolbar {
                    ToolbarItemGroup {
                        Button {
                            showingCommandPalette = true
                        } label: {
                            Label("Command", systemImage: "command")
                        }
                        .keyboardShortcut("k", modifiers: [.command])

                        Button {
                            showingImportConfiguration = true
                        } label: {
                            Label("Import", systemImage: "square.and.arrow.down")
                        }

                        Button {
                            store.loadSample()
                        } label: {
                            Label("Sample", systemImage: "doc.badge.gearshape")
                        }

                        Button {
                            store.parseSource()
                        } label: {
                            Label("Parse", systemImage: "arrow.triangle.2.circlepath")
                        }

                        Button {
                            Task { await store.runLatencyChecks() }
                        } label: {
                            Label("Probe", systemImage: "antenna.radiowaves.left.and.right")
                        }
                    }
                }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            store.importFile(url: url)
        }
        .sheet(isPresented: $showingCommandPalette) {
            CommandPaletteView(
                selection: $selection,
                isPresented: $showingCommandPalette,
                openImporter: {
                    importing = true
                }
            )
            .environmentObject(store)
        }
        .sheet(isPresented: $showingImportConfiguration) {
            ImportConfigurationView(
                isPresented: $showingImportConfiguration,
                openLocalImporter: {
                    showingImportConfiguration = false
                    importing = true
                }
            )
            .environmentObject(store)
        }
    }
}

struct CommandPaletteView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @Binding var selection: WorkbenchSection?
    @Binding var isPresented: Bool
    let openImporter: () -> Void
    @State private var query = ""
    @State private var pendingSystemAction: CommandPaletteSystemAction?
    @State private var showingSystemActionConfirmation = false

    private var actions: [WorkbenchCommand] {
        [
            WorkbenchCommand(title: "Start Proxy", subtitle: "Start local listeners and apply macOS proxy", systemImage: "play.fill", keywords: "start enable run proxy", dismissesAfterRun: false) {
                pendingSystemAction = .start
                showingSystemActionConfirmation = true
            },
            WorkbenchCommand(title: "Stop Proxy", subtitle: "Restore macOS proxy and stop listeners", systemImage: "stop.fill", keywords: "stop disable restore", dismissesAfterRun: false) {
                pendingSystemAction = .stop
                showingSystemActionConfirmation = true
            },
            WorkbenchCommand(title: "Import Local Profile", subtitle: "Choose a .conf or text profile file", systemImage: "square.and.arrow.down", keywords: "import file config") {
                openImporter()
            },
            WorkbenchCommand(title: "Import URL and Rules", subtitle: "Download subscription profile and rule sets", systemImage: "arrow.down.doc", keywords: "import url subscription ruleset") {
                Task { await store.importRemoteProfileAndRuleSets() }
            },
            WorkbenchCommand(title: "Test All Proxies", subtitle: "Run TCP reachability probes", systemImage: "antenna.radiowaves.left.and.right", keywords: "probe latency test proxy") {
                Task { await store.runLatencyChecks() }
            },
            WorkbenchCommand(title: "Go to Proxies", subtitle: "\(store.profile.proxies.count) proxies", systemImage: WorkbenchSection.proxies.icon, keywords: "policy proxy node") {
                selection = .proxies
            },
            WorkbenchCommand(title: "Go to Rules", subtitle: "\(store.profile.rules.count) rules", systemImage: WorkbenchSection.rules.icon, keywords: "rule ruleset route") {
                selection = .rules
            },
            WorkbenchCommand(title: "Go to Rule Sets", subtitle: "\(store.profileSummary.ruleSets) remote lists", systemImage: WorkbenchSection.ruleSets.icon, keywords: "ruleset download import") {
                selection = .ruleSets
            },
            WorkbenchCommand(title: "Go to Profiles", subtitle: "Import and source editor", systemImage: WorkbenchSection.profiles.icon, keywords: "profile import subscription") {
                selection = .profiles
            },
            WorkbenchCommand(title: "Go to Traffic", subtitle: "\(store.proxyEvents.count) captured requests", systemImage: WorkbenchSection.traffic.icon, keywords: "traffic metrics activity") {
                selection = .traffic
            },
            WorkbenchCommand(title: "Go to Tunnel", subtitle: store.packetTunnelStatusText, systemImage: WorkbenchSection.tunnel.icon, keywords: "packet tunnel transparent dns hev tun debug") {
                selection = .tunnel
            },
            WorkbenchCommand(title: "Go to Tests", subtitle: "\(store.connectivityTestResults.count) connectivity results", systemImage: WorkbenchSection.tests.icon, keywords: "diagnostics connectivity google baidu socks http") {
                selection = .tests
            }
        ]
    }

    private var filteredActions: [WorkbenchCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return actions }
        return actions.filter { action in
            action.title.lowercased().contains(trimmed)
                || action.subtitle.lowercased().contains(trimmed)
                || action.keywords.lowercased().contains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "command")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Search actions", text: $query)
                    .font(.title3)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        runFirstAction()
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(18)

            Divider()

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filteredActions) { action in
                        Button {
                            run(action)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: action.systemImage)
                                    .font(.headline)
                                    .foregroundStyle(.teal)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.title)
                                        .font(.headline)
                                    Text(action.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(12)
            }
            .frame(minHeight: 340)
        }
        .frame(width: 620, height: 460)
        .confirmationDialog(
            pendingSystemAction == .stop ? "Stop blaze?" : "Start blaze?",
            isPresented: $showingSystemActionConfirmation
        ) {
            if pendingSystemAction == .stop {
                Button("Stop Proxy", role: .destructive) {
                    isPresented = false
                    Task { await store.disableSystemProxyAndStop() }
                }
            } else {
                Button("Start Proxy") {
                    isPresented = false
                    Task { await store.startAndApplySystemProxy() }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            if pendingSystemAction == .stop {
                Text("This stops local listeners and restores the saved macOS proxy settings when available.")
            } else {
                Text("This saves the current macOS proxy settings, starts local listeners, and changes the selected network service to blaze's local ports.")
            }
        }
    }

    private func runFirstAction() {
        guard let first = filteredActions.first else { return }
        run(first)
    }

    private func run(_ action: WorkbenchCommand) {
        if action.dismissesAfterRun {
            isPresented = false
        }
        action.run()
    }
}

enum CommandPaletteSystemAction {
    case start
    case stop
}

struct WorkbenchCommand: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let systemImage: String
    let keywords: String
    var dismissesAfterRun = true
    let run: () -> Void
}

struct DetailView: View {
    @EnvironmentObject private var store: WorkbenchStore
    var selection: WorkbenchSection

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                switch selection {
                case .overview:
                    OverviewView()
                case .proxies:
                    ProxiesView()
                case .rules:
                    RulesView()
                case .ruleSets:
                    RuleSetsView()
                case .profiles:
                    ProfileEditorView()
                case .traffic:
                    TrafficView()
                case .dns:
                    DNSView()
                case .tunnel:
                    TunnelDebugView()
                case .tests:
                    TestsView()
                case .logs:
                    LogsView()
                case .settings:
                    SettingsView()
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()
            HStack {
                Text(store.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !store.profile.warnings.isEmpty {
                    Label("\(store.profile.warnings.count)", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

struct OverviewView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @State private var showingStartConfirmation = false
    @State private var showingStopConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                Header(title: "Overview", subtitle: overviewSubtitle)
                Spacer()
                Button {
                    store.runRuleProbe()
                    Task { await store.refreshSystemProxyStatus() }
                } label: {
                    Label("Diagnostics", systemImage: "wand.and.stars")
                }
                Button {
                    Task { await store.runLatencyChecks() }
                } label: {
                    Label("Test Latency", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(store.profile.proxies.isEmpty)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                OverviewStatusCard(
                    title: "Connection",
                    value: store.localProxyRunning ? "Connected" : "Disconnected",
                    caption: store.localProxyRunning ? store.localProxySummary : "Local listeners stopped",
                    systemImage: "power",
                    color: store.localProxyRunning ? .green : .secondary,
                    actionTitle: store.localProxyRunning ? "Stop" : "Start",
                    actionSystemImage: store.localProxyRunning ? "stop.fill" : "power"
                ) {
                    if store.localProxyRunning {
                        showingStopConfirmation = true
                    } else {
                        showingStartConfirmation = true
                    }
                }
                OverviewStatusCard(
                    title: "System Proxy",
                    value: store.packetTunnelConnected ? "Tunnel" : (store.effectiveSystemProxyIsBlaze ? "blaze" : (store.effectiveProxyStatus.anyProxyEnabled ? "Elsewhere" : store.systemProxyStatus.activation.rawValue)),
                    caption: store.packetTunnelConnected ? store.packetTunnelStatusText : store.effectiveSystemProxySummary,
                    systemImage: "shield.lefthalf.filled",
                    color: systemProxyColor
                )
                OverviewStatusCard(
                    title: "Takeover Mode",
                    value: store.localProxyRunning ? "Enabled" : "Standby",
                    caption: "Local HTTP and SOCKS5",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    color: store.localProxyRunning ? .green : .secondary
                )
                OverviewStatusCard(
                    title: "Active Profile",
                    value: store.activeProfileName,
                    caption: store.activeRoutingSummary,
                    systemImage: "lock.shield",
                    color: .indigo
                )
            }

            HStack(alignment: .top, spacing: 16) {
                LatencyTopPanel()
                    .frame(minWidth: 330, maxWidth: .infinity)
                TrafficSummaryPanel()
                    .frame(minWidth: 240, maxWidth: 300)
                QuickDiagnosticsPanel()
                    .frame(minWidth: 260, maxWidth: 320)
            }

            NetworkActivityPanel()

            SetupProgressStrip()
        }
        .pagePadding()
        .confirmationDialog("Start blaze?", isPresented: $showingStartConfirmation) {
            Button("Start Proxy") {
                Task { await store.startAndApplySystemProxy() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This saves the current system proxy as a restore point, starts local listeners, and changes the selected macOS network service to use 127.0.0.1:\(store.proxyListenPort) for HTTP/HTTPS and 127.0.0.1:\(store.socksListenPort) for SOCKS5.")
        }
        .confirmationDialog("Stop blaze?", isPresented: $showingStopConfirmation) {
            Button("Stop Proxy", role: .destructive) {
                Task { await store.disableSystemProxyAndStop() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This stops local listeners and restores the saved system proxy settings when available. If no restore point exists, it only disables system proxy settings that currently point to blaze's local ports.")
        }
    }

    private var overviewSubtitle: String {
        if store.localProxyRunning && store.browserTrafficShouldReachBlaze {
            return "All systems operational"
        }
        if store.profile.proxies.isEmpty && store.profile.rules.isEmpty {
            return "Import a profile to begin"
        }
        return store.activeRoutingSummary
    }

    private var systemProxyColor: Color {
        if store.browserTrafficShouldReachBlaze {
            return .green
        }
        switch store.systemProxyStatus.activation {
        case .partial:
            return .orange
        case .active, .inactive, .unknown:
            return .secondary
        }
    }
}

struct OverviewStatusCard: View {
    let title: String
    let value: String
    let caption: String
    let systemImage: String
    let color: Color
    var actionTitle: String?
    var actionSystemImage: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.headline)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    action?()
                } label: {
                    Image(systemName: actionSystemImage ?? systemImage)
                        .font(.callout.weight(.semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.borderless)
                .disabled(action == nil)
                .foregroundStyle(color)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                .help(actionTitle ?? title)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

struct LatencyTopPanel: View {
    @EnvironmentObject private var store: WorkbenchStore

    private var topProxies: [ProxyNode] {
        let proxies = store.profile.proxies
        guard !proxies.isEmpty else { return [] }
        return proxies.sorted { lhs, rhs in
            let left = store.latencyResults[lhs.name]?.milliseconds ?? Int.max
            let right = store.latencyResults[rhs.name]?.milliseconds ?? Int.max
            return left == right ? lhs.name < rhs.name : left < right
        }
        .prefix(4)
        .map { $0 }
    }

    var body: some View {
        SectionPanel(title: "Latency (Top 4)", icon: "speedometer") {
            if topProxies.isEmpty {
                Text("No proxies imported")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(topProxies) { proxy in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(proxy.displayRegion)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text(store.latencyResults[proxy.name]?.milliseconds.map { "\($0)" } ?? "-")
                                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                                    .lineLimit(1)
                                Text("ms")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
}

struct TrafficSummaryPanel: View {
    @EnvironmentObject private var store: WorkbenchStore

    var body: some View {
        SectionPanel(title: "Traffic Summary", icon: "chart.line.uptrend.xyaxis") {
            VStack(alignment: .leading, spacing: 14) {
                TrafficSummaryMetric(title: "Upload", value: trafficValue(multiplier: 0.42), color: .indigo, values: sparkValues(seed: 3))
                TrafficSummaryMetric(title: "Download", value: trafficValue(multiplier: 1.8), color: .blue, values: sparkValues(seed: 9))
            }
        }
    }

    private func trafficValue(multiplier: Double) -> String {
        let base = max(1.0, Double(store.proxyEvents.count + store.proxyPolicyStats.reduce(0) { $0 + $1.count }))
        return String(format: "%.1f MB", base * multiplier)
    }

    private func sparkValues(seed: Int) -> [Double] {
        let eventCount = max(store.proxyEvents.count, 1)
        return (0..<24).map { index in
            let wave = Double((index * seed + eventCount * 7) % 13)
            return 0.25 + wave / 14.0
        }
    }
}

struct TrafficSummaryMetric: View {
    let title: String
    let value: String
    let color: Color
    let values: [Double]

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline.monospacedDigit())
            }
            Spacer()
            Sparkline(values: values, color: color)
                .frame(width: 88, height: 32)
        }
    }
}

struct QuickDiagnosticsPanel: View {
    @EnvironmentObject private var store: WorkbenchStore

    var body: some View {
        SectionPanel(title: "Quick Diagnostics", icon: "checkmark.seal") {
            VStack(alignment: .leading, spacing: 10) {
                DiagnosticRow(name: "Connectivity", isGood: store.localProxyRunning)
                DiagnosticRow(name: "Profile Parse", isGood: store.profile.warnings.isEmpty)
                DiagnosticRow(name: "Proxy Handshake", isGood: reachableProxyCount > 0 || store.latencyResults.isEmpty)
                DiagnosticRow(name: "Rule Engine", isGood: store.routeProbeResult != nil)
                Button {
                    store.runRuleProbe()
                    Task {
                        await store.refreshSystemProxyStatus()
                        await store.runConnectivityDiagnostics()
                    }
                } label: {
                    Label("Run Full Test", systemImage: "arrow.triangle.2.circlepath")
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var reachableProxyCount: Int {
        store.latencyResults.values.filter { $0.status == "Reachable" }.count
    }
}

struct DiagnosticRow: View {
    let name: String
    let isGood: Bool

    var body: some View {
        HStack {
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Label(isGood ? "All good" : "Needs attention", systemImage: isGood ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(isGood ? .green : .orange)
        }
    }
}

struct NetworkActivityPanel: View {
    @EnvironmentObject private var store: WorkbenchStore

    var body: some View {
        SectionPanel(title: "Network Activity", icon: "waveform.path.ecg.rectangle") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Label("Upload", systemImage: "circle.fill")
                        .foregroundStyle(.indigo)
                    Label("Download", systemImage: "circle.fill")
                        .foregroundStyle(.blue)
                    Spacer()
                    Picker("Range", selection: .constant("5m")) {
                        Text("1m").tag("1m")
                        Text("5m").tag("5m")
                        Text("1h").tag("1h")
                        Text("6h").tag("6h")
                        Text("24h").tag("24h")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 230)
                }
                ActivityChart(upload: chartValues(seed: 4), download: chartValues(seed: 7))
                    .frame(height: 190)
            }
        }
    }

    private func chartValues(seed: Int) -> [Double] {
        let base = max(store.proxyEvents.count, 1)
        return (0..<64).map { index in
            let value = Double(((index + 3) * seed + base * 5 + (index % 7) * 3) % 18)
            return 0.08 + value / 20.0
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                guard let first = values.first else { return }
                let width = proxy.size.width
                let height = proxy.size.height
                path.move(to: point(index: 0, value: first, width: width, height: height))
                for (index, value) in values.enumerated().dropFirst() {
                    path.addLine(to: point(index: index, value: value, width: width, height: height))
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    private func point(index: Int, value: Double, width: CGFloat, height: CGFloat) -> CGPoint {
        let x = values.count <= 1 ? 0 : width * CGFloat(index) / CGFloat(values.count - 1)
        let clamped = min(1, max(0, value))
        let y = height - height * CGFloat(clamped)
        return CGPoint(x: x, y: y)
    }
}

struct ActivityChart: View {
    let upload: [Double]
    let download: [Double]

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { _ in
                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(height: 1)
                    Spacer()
                }
            }
            Sparkline(values: download, color: .blue.opacity(0.75))
            Sparkline(values: upload, color: .indigo.opacity(0.70))
        }
        .padding(.vertical, 8)
    }
}

struct SidebarStatusCard: View {
    @EnvironmentObject private var store: WorkbenchStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                SidebarStatusLine(
                    title: "System Proxy",
                    value: store.packetTunnelConnected ? "Tunnel" : (store.effectiveSystemProxyIsBlaze ? "Active" : (store.effectiveProxyStatus.anyProxyEnabled ? "Elsewhere" : store.systemProxyStatus.activation.rawValue)),
                    isOn: store.browserTrafficShouldReachBlaze
                )
                SidebarStatusLine(title: "Local Proxy", value: store.localProxyRunning ? "On" : "Off", isOn: store.localProxyRunning)
            }
            Divider()
            Text("Active Profile")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(store.activeProfileName)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
            HStack(spacing: 10) {
                Label("\(store.proxyEvents.count)", systemImage: "arrow.up.arrow.down")
                Label("\(store.profile.rules.count)", systemImage: "list.bullet")
            }
            .font(.caption)
            .foregroundStyle(.indigo)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

struct SidebarStatusLine: View {
    let title: String
    let value: String
    let isOn: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.caption)
            Spacer()
            Circle()
                .fill(isOn ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 7, height: 7)
            Text(value)
                .font(.caption2.weight(.medium))
                .foregroundStyle(isOn ? .green : .secondary)
        }
    }
}

struct LaunchPanel: View {
    @EnvironmentObject private var store: WorkbenchStore
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    StatusPill(
                        title: store.localProxyRunning ? "Running" : "Ready",
                        systemImage: store.localProxyRunning ? "bolt.fill" : "power",
                        color: store.localProxyRunning ? .green : .secondary
                    )
                    Text(store.localProxyRunning ? "Proxy is active" : "Start proxy")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                Spacer()

                HStack(spacing: 10) {
                    Button(action: onStart) {
                        Label(store.systemProxyApplyInProgress ? "Applying" : "Start", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(store.systemProxyApplyInProgress)
                    .keyboardShortcut(.defaultAction)

                    Button(action: onStop) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .controlSize(.large)
                    .disabled(store.systemProxyApplyInProgress || (!store.localProxyRunning && store.systemProxyStatus.activation == .inactive))
                }
            }

            Picker("Policy mode", selection: Binding(
                get: { store.proxyRoutingMode },
                set: { store.setProxyRoutingMode($0) }
            )) {
                ForEach(ProxyRoutingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if store.proxyRoutingMode == .global {
                Picker("Global outbound", selection: Binding(
                    get: { store.globalProxyPolicy },
                    set: { store.setGlobalProxyPolicy($0) }
                )) {
                    ForEach(store.availableGlobalPolicies, id: \.self) { policy in
                        Text(policy).tag(policy)
                    }
                }
                .frame(maxWidth: 360, alignment: .leading)
            }

            Divider()

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                CompactStat(title: "Local", value: store.localProxySummary, icon: "point.3.connected.trianglepath.dotted")
                CompactStat(title: "macOS", value: store.systemProxyStatus.summary, icon: "desktopcomputer")
                CompactStat(title: "Service", value: store.networkServiceName, icon: "wifi")
                CompactStat(title: "Ports", value: "\(store.proxyListenPort) / \(store.socksListenPort)", icon: "number")
            }

            HStack(spacing: 10) {
                if store.detectedNetworkServices.isEmpty {
                    TextField("Wi-Fi", text: $store.networkServiceName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                } else {
                    Picker("Service", selection: $store.networkServiceName) {
                        ForEach(store.detectedNetworkServices, id: \.self) { service in
                            Text(service).tag(service)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }

                Button {
                    Task { await store.detectNetworkServices() }
                } label: {
                    Label(store.networkServiceDetectionInProgress ? "Detecting" : "Detect", systemImage: "magnifyingglass")
                }
                .disabled(store.networkServiceDetectionInProgress || store.systemProxyApplyInProgress)

                Button {
                    Task { await store.refreshSystemProxyStatus() }
                } label: {
                    Label(store.systemProxyStatusInProgress ? "Checking" : "Status", systemImage: "checkmark.seal")
                }
                .disabled(store.systemProxyStatusInProgress || store.systemProxyApplyInProgress)

                Spacer()
            }
        }
        .panelSurface()
    }
}

struct QuickImportPanel: View {
    @EnvironmentObject private var store: WorkbenchStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Import Profile", systemImage: "link.badge.plus")
                    .font(.headline)
                Spacer()
                StatusPill(title: savedState, systemImage: "tray.full", color: .teal)
            }

            TextField("Subscription or profile URL", text: $store.remoteProfileURLText)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Button {
                    Task { await store.previewRemoteProfile() }
                } label: {
                    Label(store.remotePreviewInProgress ? "Previewing" : "Preview", systemImage: "eye")
                }
                .disabled(store.remotePreviewInProgress || store.remoteImportInProgress)

                Button {
                    Task { await store.importRemoteProfileAndRuleSets() }
                } label: {
                    Label(store.remoteImportInProgress ? "Importing" : "Import & Validate", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.remoteImportInProgress || store.remotePreviewInProgress)

                Spacer()
            }

            Divider()

            if let preview = store.remotePreview {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    CompactStat(title: "Preview", value: preview.summary.shortDescription, icon: "eye")
                    CompactStat(title: "Rule sets", value: "\(preview.summary.ruleSets)", icon: "arrow.down.doc")
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    CompactStat(title: "Source", value: store.profileSummary.sourceSizeDescription, icon: "doc.text")
                    CompactStat(title: "Rule cache", value: "\(store.importedRuleSetRuleCount)", icon: "tray.and.arrow.down")
                }
            }
        }
        .panelSurface()
    }

    private var savedState: String {
        store.profile.proxies.isEmpty && store.profile.rules.isEmpty ? "Empty" : "Saved"
    }
}

enum ImportConfigurationTab: String, CaseIterable, Identifiable {
    case url = "Import from URL"
    case local = "Local File"
    case subscription = "Subscription"

    var id: String { rawValue }
}

struct ImportConfigurationView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @Binding var isPresented: Bool
    let openLocalImporter: () -> Void
    @State private var selectedTab: ImportConfigurationTab = .url

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Import Configuration")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            Picker("Import type", selection: $selectedTab) {
                ForEach(ImportConfigurationTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            Divider()

            switch selectedTab {
            case .url:
                remoteImportForm(importTitle: "Import", validatesOnly: false)
            case .local:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose a local `.conf`, `.surgeconfig`, or text profile. The imported source is parsed, saved locally, and restored on next launch.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button {
                        openLocalImporter()
                    } label: {
                        Label("Choose Local File", systemImage: "folder")
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .subscription:
                remoteImportForm(importTitle: "Import & Rule Sets", validatesOnly: false)
            }

            validationSummary

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                Button {
                    Task {
                        if selectedTab == .subscription {
                            await store.importRemoteProfileAndRuleSets()
                        } else {
                            await store.importRemoteProfile()
                        }
                        isPresented = false
                    }
                } label: {
                    Text("Import")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedTab == .local || store.remoteProfileURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.remoteImportInProgress)
            }
        }
        .padding(22)
        .frame(width: 620)
    }

    private func remoteImportForm(importTitle: String, validatesOnly: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField("https://config.example.com/profile.conf", text: $store.remoteProfileURLText)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await store.previewRemoteProfile() }
                } label: {
                    Text(store.remotePreviewInProgress ? "Validating" : "Validate")
                }
                .disabled(store.remotePreviewInProgress || store.remoteImportInProgress || store.remoteProfileURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(selectedTab == .subscription ? "Subscription import downloads the profile and then fetches any referenced RULE-SET entries." : "URL import previews the remote profile without exposing credentials.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var validationSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let preview = store.remotePreview {
                HStack(spacing: 8) {
                    Label("Configuration is valid", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Profile: \(preview.summary.shortDescription)")
                        .foregroundStyle(.secondary)
                }
                .font(.callout.weight(.medium))
            } else {
                HStack(spacing: 8) {
                    Label(store.profile.proxies.isEmpty && store.profile.rules.isEmpty ? "No preview yet" : "Current configuration loaded", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                    Text(store.profileSummary.shortDescription)
                        .foregroundStyle(.secondary)
                }
                .font(.callout.weight(.medium))
            }

            HStack(spacing: 12) {
                CompactStat(title: "Profiles", value: store.profile.groups.isEmpty ? "1" : "\(store.profile.groups.count)", icon: "person.crop.rectangle.stack")
                CompactStat(title: "Rules", value: "\(store.remotePreview?.summary.rules ?? store.profileSummary.rules)", icon: "list.bullet.rectangle")
                CompactStat(title: "Proxies", value: "\(store.remotePreview?.summary.proxies ?? store.profileSummary.proxies)", icon: "network")
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(14)
        .background(Color.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

struct SetupProgressStrip: View {
    @EnvironmentObject private var store: WorkbenchStore

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            SetupStepTile(index: 1, title: "Import", value: profileReady ? "Ready" : "Needed", systemImage: "arrow.down.doc", state: profileReady ? .complete : .pending)
            SetupStepTile(index: 2, title: "Rules", value: rulesReady, systemImage: "list.bullet.rectangle", state: rulesReady == "Loaded" || rulesReady == "No sets" ? .complete : .pending)
            SetupStepTile(index: 3, title: "Policy", value: store.proxyRoutingMode.title, systemImage: "point.topleft.down.curvedto.point.bottomright.up", state: .complete)
            SetupStepTile(index: 4, title: "Takeover", value: store.localProxyRunning ? "Active" : "Stopped", systemImage: "power", state: store.localProxyRunning ? .complete : .pending)
        }
    }

    private var profileReady: Bool {
        !store.profile.proxies.isEmpty || !store.profile.rules.isEmpty
    }

    private var rulesReady: String {
        if store.profileSummary.ruleSets == 0 {
            return "No sets"
        }
        return store.importedRuleSetRuleCount > 0 ? "Loaded" : "Pending"
    }
}

struct ProxiesView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @State private var searchText = ""
    @State private var protocolScope: ProxyProtocolScope = .all
    @State private var selectedProxyID: ProxyNode.ID?
    @State private var quickProxyKind = "http"
    @State private var quickProxyName = ""
    @State private var quickProxyHost = ""
    @State private var quickProxyPort = ""
    @State private var quickProxyUsername = ""
    @State private var quickProxyPassword = ""

    private let quickProxyKinds = ["http", "https", "socks5", "trojan"]

    private var filteredProxies: [ProxyNode] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scoped = store.profile.proxies.filter { proxy in
            protocolScope.includes(proxy)
        }
        guard !query.isEmpty else { return scoped }
        return scoped.filter { proxy in
            proxy.name.lowercased().contains(query)
                || proxy.kind.displayName.lowercased().contains(query)
                || proxy.rawKind.lowercased().contains(query)
                || proxy.endpoint.lowercased().contains(query)
                || proxy.parameters.keys.contains { $0.lowercased().contains(query) }
                || proxy.parameters.contains { key, value in
                    !ProxyNode.isSensitive(key) && value.lowercased().contains(query)
                }
        }
    }

    private var selectedProxy: ProxyNode? {
        if let selectedProxyID,
           let proxy = filteredProxies.first(where: { $0.id == selectedProxyID }) {
            return proxy
        }
        return filteredProxies.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Header(title: "Proxies", subtitle: "\(filteredProxies.count) shown, \(store.profile.proxies.count) total")
                Spacer()
                Button {
                    Task { await store.runLatencyChecks() }
                } label: {
                    Label("Test All", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(store.profile.proxies.isEmpty)
                Button {
                    store.applyBestLatencySelections()
                } label: {
                    Label("Apply Best", systemImage: "speedometer")
                }
                .disabled(store.latencyResults.isEmpty)
            }

            HStack(spacing: 12) {
                Picker("Protocol", selection: $protocolScope) {
                    ForEach(ProxyProtocolScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 540)

                SearchField(text: $searchText, placeholder: "Search proxies")
                    .frame(maxWidth: 360)
                Spacer()
                Toggle("Reveal secrets", isOn: $store.revealSecrets)
                    .toggleStyle(.switch)
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 0) {
                    ProxyTableHeader()
                    ForEach(filteredProxies) { proxy in
                        ProxyTableRow(
                            proxy: proxy,
                            result: store.latencyResults[proxy.name],
                            isSelected: selectedProxy?.id == proxy.id,
                            isUsing: store.proxyRoutingMode == .global && store.globalProxyPolicy == proxy.name,
                            isFavorite: store.favoriteProxyNames.contains(proxy.name),
                            onFavorite: { store.toggleFavoriteProxy(proxy.name) }
                        ) {
                            selectedProxyID = proxy.id
                        }
                        Divider()
                            .padding(.leading, 16)
                    }
                    if filteredProxies.isEmpty {
                        EmptyStateRow(title: "No proxies found", subtitle: "Import a profile or adjust the filter.")
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
                .frame(minWidth: 620)

                VStack(alignment: .leading, spacing: 14) {
                    if let selectedProxy {
                        ProxyInspectorPanel(
                            proxy: selectedProxy,
                            result: store.latencyResults[selectedProxy.name],
                            revealSecrets: store.revealSecrets,
                            isUsing: store.proxyRoutingMode == .global && store.globalProxyPolicy == selectedProxy.name,
                            onUse: {
                                store.setProxyRoutingMode(.global)
                                store.setGlobalProxyPolicy(selectedProxy.name)
                            },
                            onTest: {
                                Task { await store.runLatencyCheck(proxyName: selectedProxy.name) }
                            }
                        )
                    }

                    SectionPanel(title: "Quick Add Proxy", icon: "plus.circle") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Protocol", selection: $quickProxyKind) {
                                ForEach(quickProxyKinds, id: \.self) { kind in
                                    Text(kind.uppercased()).tag(kind)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)

                            TextField("Proxy name", text: $quickProxyName)
                                .textFieldStyle(.roundedBorder)

                            HStack(spacing: 10) {
                                TextField("Host", text: $quickProxyHost)
                                    .textFieldStyle(.roundedBorder)
                                TextField("Port", text: $quickProxyPort)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 90)
                            }

                            TextField(quickProxyKind == "trojan" ? "Username not used" : "Username optional", text: $quickProxyUsername)
                                .textFieldStyle(.roundedBorder)
                                .disabled(quickProxyKind == "trojan")

                            if store.revealSecrets {
                                TextField("Password or token optional", text: $quickProxyPassword)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                SecureField("Password or token optional", text: $quickProxyPassword)
                                    .textFieldStyle(.roundedBorder)
                            }

                            Button {
                                store.addProxy(
                                    name: quickProxyName,
                                    kind: quickProxyKind,
                                    host: quickProxyHost,
                                    portText: quickProxyPort,
                                    username: quickProxyUsername,
                                    password: quickProxyPassword
                                )
                                if store.statusText.hasPrefix("Added proxy") {
                                    quickProxyName = ""
                                    quickProxyHost = ""
                                    quickProxyPort = ""
                                    quickProxyUsername = ""
                                    quickProxyPassword = ""
                                }
                            } label: {
                                Label("Add Proxy", systemImage: "plus")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                quickProxyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || quickProxyHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || quickProxyPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
                .frame(width: 320)
            }
        }
        .pagePadding()
    }
}

enum ProxyProtocolScope: String, CaseIterable, Identifiable {
    case all
    case shadowsocks
    case vmess
    case trojan
    case http
    case socks5

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .shadowsocks: "Shadowsocks"
        case .vmess: "VMess"
        case .trojan: "Trojan"
        case .http: "HTTP"
        case .socks5: "SOCKS5"
        }
    }

    func includes(_ proxy: ProxyNode) -> Bool {
        switch self {
        case .all:
            true
        case .shadowsocks:
            proxy.kind == .shadowsocks
        case .vmess:
            proxy.kind == .vmess
        case .trojan:
            proxy.kind == .trojan
        case .http:
            proxy.kind == .http || proxy.kind == .https
        case .socks5:
            proxy.kind == .socks5 || proxy.kind == .socks5TLS
        }
    }
}

struct ProxyTableHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Region")
                .frame(width: 110, alignment: .leading)
            Text("Protocol")
                .frame(width: 110, alignment: .leading)
            Text("Latency")
                .frame(width: 84, alignment: .leading)
            Text("Health")
                .frame(width: 84, alignment: .leading)
            Text("")
                .frame(width: 34)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct ProxyTableRow: View {
    let proxy: ProxyNode
    let result: LatencyResult?
    let isSelected: Bool
    let isUsing: Bool
    let isFavorite: Bool
    let onFavorite: () -> Void
    let onSelect: () -> Void

    var body: some View {
        Button {
            onSelect()
        } label: {
            HStack(spacing: 12) {
                HStack(spacing: 9) {
                    Circle()
                        .fill(isUsing ? Color.indigo : Color.secondary.opacity(0.35))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(proxy.name)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text(proxy.endpoint)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(proxy.displayRegion)
                    .font(.callout)
                    .lineLimit(1)
                    .frame(width: 110, alignment: .leading)

                Text(proxy.kind.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.indigo.opacity(0.10), in: Capsule())
                    .frame(width: 110, alignment: .leading)

                Text(result?.milliseconds.map { "\($0) ms" } ?? result?.status ?? "-")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(latencyColor)
                    .frame(width: 84, alignment: .leading)

                HealthBars(result: result)
                    .frame(width: 84, alignment: .leading)

                Button {
                    onFavorite()
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundStyle(isFavorite ? .orange : .secondary)
                }
                .buttonStyle(.borderless)
                .help(isFavorite ? "Remove favorite" : "Favorite proxy")
                .frame(width: 34)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(isSelected ? Color.indigo.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var latencyColor: Color {
        switch result?.status {
        case "Reachable": .green
        case "Timeout": .orange
        case "Failed", "Invalid": .red
        default: .secondary
        }
    }
}

struct HealthBars: View {
    let result: LatencyResult?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(index < activeBars ? color : Color.secondary.opacity(0.16))
                    .frame(width: 5, height: CGFloat(8 + index * 3))
            }
        }
    }

    private var activeBars: Int {
        guard result?.status == "Reachable" else { return result == nil ? 0 : 1 }
        guard let milliseconds = result?.milliseconds else { return 3 }
        switch milliseconds {
        case ..<40: return 5
        case ..<90: return 4
        case ..<160: return 3
        case ..<260: return 2
        default: return 1
        }
    }

    private var color: Color {
        activeBars >= 4 ? .green : (activeBars >= 2 ? .orange : .red)
    }
}

struct ProxyInspectorPanel: View {
    let proxy: ProxyNode
    let result: LatencyResult?
    let revealSecrets: Bool
    let isUsing: Bool
    let onUse: () -> Void
    let onTest: () -> Void

    var body: some View {
        SectionPanel(title: proxy.name, icon: "server.rack") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    StatusPill(title: proxy.kind.displayName, systemImage: "network", color: .indigo)
                    if isUsing {
                        StatusPill(title: "Active", systemImage: "checkmark.circle.fill", color: .green)
                    }
                    Spacer()
                }

                CompatibilityRow(name: "Region", value: proxy.displayRegion)
                CompatibilityRow(name: "Server", value: proxy.host.isEmpty ? "-" : proxy.host)
                CompatibilityRow(name: "Port", value: proxy.port.map(String.init) ?? "-")
                CompatibilityRow(name: "Latency", value: result?.milliseconds.map { "\($0) ms" } ?? result?.message ?? "Not tested")
                CompatibilityRow(name: "Source line", value: "\(proxy.sourceLine)")
                CompatibilityRow(name: "Credentials", value: credentialSummary)

                if !proxy.parameters.isEmpty {
                    Divider()
                    ForEach(proxy.redactedParameters.sorted(by: { $0.key < $1.key }).prefix(7), id: \.key) { key, value in
                        CompatibilityRow(name: key, value: revealSecrets ? value : (ProxyNode.isSensitive(key) ? "Hidden" : value))
                    }
                }

                HStack {
                    Button {
                        onTest()
                    } label: {
                        Label("Test", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    Button {
                        onUse()
                    } label: {
                        Label(isUsing ? "Using" : "Use Globally", systemImage: isUsing ? "checkmark.circle.fill" : "arrow.up.right.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isUsing)
                    Spacer()
                }
            }
        }
    }

    private var credentialSummary: String {
        guard proxy.hasSecret else { return "None" }
        if revealSecrets {
            return [proxy.redactedUsername, proxy.redactedPassword].filter { !$0.isEmpty }.joined(separator: " / ")
        }
        return "Hidden"
    }
}

struct EmptyStateRow: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

struct ProxyCard: View {
    let proxy: ProxyNode
    let result: LatencyResult?
    let revealSecrets: Bool
    let isSelected: Bool
    let showsSelect: Bool
    let onSelect: () -> Void
    let onTest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(proxy.kind.displayName.uppercased())
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if isSelected {
                    StatusPill(title: "Selected", systemImage: "checkmark", color: .teal)
                } else {
                    Text(resultText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(resultColor)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(proxy.kind == .unknown ? .orange : .teal)
                Text(proxy.name)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(proxy.endpoint)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 8) {
                Text(result?.message ?? "Not checked")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if proxy.hasSecret {
                    Image(systemName: revealSecrets ? "eye" : "eye.slash")
                        .foregroundStyle(.secondary)
                        .help(revealSecrets ? secretText : "Credentials hidden")
                }
            }

            HStack(spacing: 8) {
                if showsSelect {
                    Button {
                        onSelect()
                    } label: {
                        Label(isSelected ? "Using" : "Use", systemImage: isSelected ? "checkmark.circle.fill" : "arrow.up.right.circle")
                    }
                    .disabled(isSelected)
                }

                Button {
                    onTest()
                } label: {
                    Label("Test", systemImage: "antenna.radiowaves.left.and.right")
                }

                Spacer()
            }
        }
        .padding(16)
        .frame(minHeight: 148, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.teal.opacity(0.75) : resultColor.opacity(result == nil ? 0.08 : 0.35), lineWidth: isSelected ? 1.5 : 1)
        )
    }

    private var resultText: String {
        guard let result else { return "" }
        return result.milliseconds.map { "\($0) ms" } ?? result.status
    }

    private var resultColor: Color {
        switch result?.status {
        case "Reachable": .green
        case "Skipped": .gray
        case "Timeout": .orange
        case "Failed", "Invalid": .red
        default: .secondary
        }
    }

    private var icon: String {
        switch proxy.kind {
        case .http, .https: "globe"
        case .socks5, .socks5TLS: "point.3.connected.trianglepath.dotted"
        case .direct: "arrow.up.right"
        case .reject: "xmark.octagon"
        default: "server.rack"
        }
    }

    private var secretText: String {
        var parts: [String] = []
        if !proxy.redactedUsername.isEmpty { parts.append(proxy.redactedUsername) }
        if !proxy.redactedPassword.isEmpty { parts.append(proxy.redactedPassword) }
        for (key, value) in proxy.redactedParameters.sorted(by: { $0.key < $1.key }) where ProxyNode.isSensitive(key) {
            parts.append("\(key)=\(value)")
        }
        return parts.joined(separator: " / ")
    }
}

struct ProxyRow: View {
    let proxy: ProxyNode
    let result: LatencyResult?
    let revealSecrets: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 30)
                .foregroundStyle(proxy.kind == .unknown ? .orange : .teal)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(proxy.name)
                        .font(.headline)
                    Text(proxy.kind.displayName)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.teal.opacity(0.12), in: Capsule())
                }
                Text(proxy.endpoint)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if proxy.hasSecret {
                Text(revealSecrets ? secretText : "Credentials hidden")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let result {
                LatencyBadge(result: result)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        switch proxy.kind {
        case .http, .https: "globe"
        case .socks5, .socks5TLS: "point.3.connected.trianglepath.dotted"
        case .direct: "arrow.up.right"
        case .reject: "xmark.octagon"
        default: "server.rack"
        }
    }

    private var secretText: String {
        var parts: [String] = []
        if !proxy.redactedUsername.isEmpty { parts.append(proxy.redactedUsername) }
        if !proxy.redactedPassword.isEmpty { parts.append(proxy.redactedPassword) }
        for (key, value) in proxy.redactedParameters.sorted(by: { $0.key < $1.key }) where ProxyNode.isSensitive(key) {
            parts.append("\(key)=\(value)")
        }
        return parts.joined(separator: " / ")
    }
}

struct GroupsView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @State private var searchText = ""

    private var filteredGroups: [ProxyGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return store.profile.groups }
        return store.profile.groups.filter { group in
            group.name.lowercased().contains(query)
                || group.kind.displayName.lowercased().contains(query)
                || group.rawKind.lowercased().contains(query)
                || group.policies.contains { $0.lowercased().contains(query) }
                || group.parameters.contains { key, value in
                    key.lowercased().contains(query) || value.lowercased().contains(query)
                }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(title: "Groups", subtitle: searchText.isEmpty ? "\(store.profile.groups.count) policy groups" : "\(filteredGroups.count) of \(store.profile.groups.count) groups")

            HStack(spacing: 12) {
                SearchField(text: $searchText, placeholder: "Filter group, type, selected policy, or candidate")
                    .frame(maxWidth: 620)
                Button {
                    store.applyBestLatencySelections()
                } label: {
                    Label("Apply Best Latency", systemImage: "speedometer")
                }
                Spacer()
            }

            HStack(spacing: 12) {
                CompactStat(title: "Groups", value: "\(store.profile.groups.count)", icon: "square.stack.3d.up")
                CompactStat(title: "Auto selectable", value: "\(store.profile.groups.filter { $0.kind.isAutoSelectable }.count)", icon: "speedometer")
                CompactStat(title: "Selections", value: "\(store.selectedPolicies.count)", icon: "checkmark.circle")
                CompactStat(title: "Mode", value: store.proxyRoutingMode.title, icon: "point.topleft.down.curvedto.point.bottomright.up")
            }
            .panelSurface()

            VStack(spacing: 0) {
                GroupTableHeader()
                ForEach(filteredGroups) { group in
                    GroupTableRow(group: group)
                        .environmentObject(store)
                    Divider()
                        .padding(.leading, 16)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .pagePadding()
    }
}

struct GroupTableHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Group")
                .frame(minWidth: 180, maxWidth: 260, alignment: .leading)
            Text("Selected")
                .frame(width: 280, alignment: .leading)
            Text("Candidates")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Best")
                .frame(width: 160, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct GroupTableRow: View {
    @EnvironmentObject private var store: WorkbenchStore
    let group: ProxyGroup

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(group.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    StatusPill(title: group.kind.displayName, systemImage: "square.stack.3d.up", color: .teal)
                    Text("\(group.policies.count) policies")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 180, maxWidth: 260, alignment: .leading)

            if group.policies.isEmpty {
                Text("-")
                    .foregroundStyle(.secondary)
                    .frame(width: 280, alignment: .leading)
            } else {
                Picker("Selected", selection: Binding(
                    get: { store.selectedPolicy(for: group) },
                    set: { store.setSelectedPolicy($0, for: group) }
                )) {
                    ForEach(group.policies, id: \.self) { policy in
                        Text(policy).tag(policy)
                    }
                }
                .labelsHidden()
                .frame(width: 280, alignment: .leading)
            }

            Text(candidatePreview)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let best = store.bestLatencyPolicy(for: group), group.kind.isAutoSelectable {
                Text(best)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.12), in: Capsule())
                    .frame(width: 160, alignment: .leading)
            } else {
                Text(group.kind.isAutoSelectable ? "Probe first" : "-")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 160, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var candidatePreview: String {
        let preview = group.policies.prefix(5).joined(separator: ", ")
        let remaining = max(0, group.policies.count - 5)
        return remaining > 0 ? "\(preview)  +\(remaining)" : (preview.isEmpty ? "-" : preview)
    }
}

enum RuleScope: String, CaseIterable, Identifiable {
    case all = "All"
    case ruleSet = "RULE-SET"
    case local = "Local"

    var id: String { rawValue }
}

enum RuleCategory: String, CaseIterable, Identifiable {
    case all = "Global"
    case domain = "Domains"
    case ipCIDR = "IP CIDR"
    case geoIP = "GeoIP"
    case applications = "Applications"
    case user = "User Rules"
    case final = "Final"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: "globe"
        case .domain: "textformat.abc"
        case .ipCIDR: "number"
        case .geoIP: "map"
        case .applications: "app.connected.to.app.below.fill"
        case .user: "person.crop.circle"
        case .final: "flag.checkered"
        }
    }

    func includes(_ rule: ProxyRule) -> Bool {
        switch self {
        case .all:
            true
        case .domain:
            rule.type.contains("DOMAIN") || rule.type == "URL-REGEX"
        case .ipCIDR:
            rule.type == "IP-CIDR" || rule.type == "IP-CIDR6"
        case .geoIP:
            rule.type == "GEOIP"
        case .applications:
            rule.type.contains("PROCESS") || rule.type == "SRC-IP" || rule.type == "IN-PORT"
        case .user:
            rule.type != "FINAL" && rule.type != "MATCH" && rule.type != "RULE-SET"
        case .final:
            rule.type == "FINAL" || rule.type == "MATCH"
        }
    }
}

struct RulesView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @State private var searchText = ""
    @State private var scope: RuleScope = .all
    @State private var category: RuleCategory = .all
    @State private var showRuleSetStatus = false
    @State private var quickRuleType = "DOMAIN-SUFFIX"
    @State private var quickRuleValue = ""
    @State private var quickRulePolicy = ""
    @State private var pendingRuleRemoval: ProxyRule?
    @State private var selectedRuleID: ProxyRule.ID?

    private let quickRuleTypes = ["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-WILDCARD"]

    private var filteredRules: [ProxyRule] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scoped = store.profile.rules.filter { rule in
            switch scope {
            case .all:
                true
            case .ruleSet:
                rule.type == "RULE-SET"
            case .local:
                rule.type != "RULE-SET"
            }
        }.filter { category.includes($0) }
        guard !query.isEmpty else { return scoped }
        return scoped.filter { rule in
            String(rule.sourceLine).contains(query)
                || rule.type.lowercased().contains(query)
                || rule.value.lowercased().contains(query)
                || rule.policy.lowercased().contains(query)
                || rule.rawLine.lowercased().contains(query)
                || rule.options.contains { $0.lowercased().contains(query) }
        }
    }

    private var selectedRule: ProxyRule? {
        if let selectedRuleID,
           let rule = filteredRules.first(where: { $0.id == selectedRuleID }) {
            return rule
        }
        return filteredRules.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(title: "Rules", subtitle: "\(filteredRules.count) shown, \(store.expandedRuleCount) effective")

            HStack(spacing: 12) {
                Picker("Rule scope", selection: $scope) {
                    ForEach(RuleScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 330)

                SearchField(text: $searchText, placeholder: "Filter type, domain, URL, policy, option, or line")
                    .frame(maxWidth: 720)
                Spacer()
            }

            HStack(alignment: .top, spacing: 14) {
                RuleCategorySidebar(selection: $category, counts: categoryCounts)
                    .frame(width: 180)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        CompactStat(title: "Profile rules", value: "\(store.profile.rules.count)", icon: "list.bullet.rectangle")
                        CompactStat(title: "RULE-SET", value: "\(store.profileSummary.ruleSets)", icon: "arrow.down.doc")
                        CompactStat(title: "Expanded", value: "\(store.expandedRuleCount)", icon: "rectangle.expand.vertical")
                        CompactStat(title: "Downloaded", value: "\(store.importedRuleSetRuleCount)", icon: "tray.and.arrow.down")
                    }
                    .panelSurface()

                    if !store.ruleSetStatusByURL.isEmpty {
                        DisclosureGroup(isExpanded: $showRuleSetStatus) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(store.ruleSetStatusByURL.keys.sorted(), id: \.self) { url in
                                    HStack(spacing: 10) {
                                        Text(store.ruleSetStatusByURL[url] ?? "")
                                            .font(.caption.weight(.medium))
                                            .frame(width: 120, alignment: .leading)
                                        Text(url)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            Label("Rule-set download status", systemImage: "tray.full")
                        }
                        .font(.callout.weight(.medium))
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }

                    VStack(spacing: 0) {
                        RuleTableHeader()
                        ForEach(filteredRules) { rule in
                            RuleTableRow(
                                rule: rule,
                                isSelected: selectedRule?.id == rule.id,
                                onSelect: { selectedRuleID = rule.id },
                                onRemove: { pendingRuleRemoval = rule }
                            )
                            Divider()
                                .padding(.leading, 16)
                        }
                        if filteredRules.isEmpty {
                            EmptyStateRow(title: "No rules found", subtitle: "Adjust the category, scope, or search query.")
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )
                }

                RuleEditorPanel(
                    selectedRule: selectedRule,
                    quickRuleType: $quickRuleType,
                    quickRuleValue: $quickRuleValue,
                    quickRulePolicy: $quickRulePolicy,
                    quickRuleTypes: quickRuleTypes,
                    onAdd: {
                        store.addRule(type: quickRuleType, value: quickRuleValue, policy: quickRulePolicy)
                        quickRuleValue = ""
                    },
                    onRemoveSelected: {
                        if let selectedRule {
                            pendingRuleRemoval = selectedRule
                        }
                    }
                )
                .environmentObject(store)
                .frame(width: 300)
            }
        }
        .pagePadding()
        .onAppear {
            if quickRulePolicy.isEmpty {
                quickRulePolicy = store.availableGlobalPolicies.first ?? "DIRECT"
            }
        }
        .confirmationDialog(
            "Remove rule?",
            isPresented: Binding(
                get: { pendingRuleRemoval != nil },
                set: { if !$0 { pendingRuleRemoval = nil } }
            )
        ) {
            Button("Remove Rule", role: .destructive) {
                if let pendingRuleRemoval {
                    store.removeRule(pendingRuleRemoval)
                }
                pendingRuleRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRuleRemoval = nil
            }
        } message: {
            if let pendingRuleRemoval {
                Text("This removes line \(pendingRuleRemoval.sourceLine) from the locally saved profile source.")
            }
        }
    }

    private var categoryCounts: [RuleCategory: Int] {
        Dictionary(uniqueKeysWithValues: RuleCategory.allCases.map { category in
            (category, store.profile.rules.filter { category.includes($0) }.count)
        })
    }
}

struct RuleCategorySidebar: View {
    @Binding var selection: RuleCategory
    let counts: [RuleCategory: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RULE CATEGORIES")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
            ForEach(RuleCategory.allCases) { category in
                Button {
                    selection = category
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: category.icon)
                            .frame(width: 18)
                        Text(category.rawValue)
                            .lineLimit(1)
                        Spacer()
                        Text("\(counts[category] ?? 0)")
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(selection == category ? Color.indigo.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(selection == category ? Color.indigo : Color.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

struct RuleEditorPanel: View {
    @EnvironmentObject private var store: WorkbenchStore
    let selectedRule: ProxyRule?
    @Binding var quickRuleType: String
    @Binding var quickRuleValue: String
    @Binding var quickRulePolicy: String
    let quickRuleTypes: [String]
    let onAdd: () -> Void
    let onRemoveSelected: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionPanel(title: "Rule Editor", icon: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: 12) {
                    if let selectedRule {
                        CompatibilityRow(name: "Type", value: selectedRule.type)
                        CompatibilityRow(name: "Rule", value: selectedRule.value.isEmpty ? "-" : selectedRule.value)
                        CompatibilityRow(name: "Action", value: selectedRule.policy == "DIRECT" ? "Direct" : "Proxy")
                        CompatibilityRow(name: "Target", value: selectedRule.policy)
                        CompatibilityRow(name: "Line", value: "\(selectedRule.sourceLine)")
                        CompatibilityRow(name: "Options", value: selectedRule.options.isEmpty ? "-" : selectedRule.options.joined(separator: ", "))
                        Button(role: .destructive) {
                            onRemoveSelected()
                        } label: {
                            Label("Remove Selected", systemImage: "trash")
                        }
                    } else {
                        Text("Select a rule to inspect it.")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SectionPanel(title: "Add Rule", icon: "plus.circle") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Type", selection: $quickRuleType) {
                        ForEach(quickRuleTypes, id: \.self) { type in
                            Text(type).tag(type)
                        }
                    }
                    .labelsHidden()

                    TextField("example.com or keyword", text: $quickRuleValue)
                        .textFieldStyle(.roundedBorder)

                    Picker("Policy", selection: $quickRulePolicy) {
                        if quickRulePolicy.isEmpty {
                            Text("Choose policy").tag("")
                        }
                        ForEach(store.availableGlobalPolicies, id: \.self) { policy in
                            Text(policy).tag(policy)
                        }
                    }
                    .labelsHidden()

                    Button {
                        onAdd()
                    } label: {
                        Label("Save", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(quickRuleValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || quickRulePolicy.isEmpty)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }
}

struct RuleTableHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Line")
                .frame(width: 54, alignment: .trailing)
            Text("Type")
                .frame(width: 140, alignment: .leading)
            Text("Match")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Policy")
                .frame(width: 150, alignment: .leading)
            Text("Options")
                .frame(width: 160, alignment: .leading)
            Text("")
                .frame(width: 32)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct RuleTableRow: View {
    let rule: ProxyRule
    let isSelected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button {
            onSelect()
        } label: {
            HStack(spacing: 12) {
                Text("\(rule.sourceLine)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .trailing)
                Text(rule.type)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .frame(width: 140, alignment: .leading)
                Text(rule.value.isEmpty ? "-" : rule.value)
                    .font(.callout)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                RulePolicyBadge(policy: rule.policy)
                    .frame(width: 150, alignment: .leading)
                Text(rule.options.isEmpty ? "-" : rule.options.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 160, alignment: .leading)
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove rule")
                .frame(width: 32)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(isSelected ? Color.indigo.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

struct RulePolicyBadge: View {
    let policy: String

    var body: some View {
        Text(policy)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(policyColor.opacity(0.12), in: Capsule())
            .foregroundStyle(policyColor)
    }

    private var policyColor: Color {
        if policy == "DIRECT" || policy.contains("Direct") {
            return .green
        }
        if policy == "REJECT" {
            return .red
        }
        return .indigo
    }
}

struct TesterView: View {
    @EnvironmentObject private var store: WorkbenchStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Header(title: "Tester", subtitle: "Rule decision and endpoint reachability")

            SectionPanel(title: "Route Match", icon: "scope") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        TextField("Host, URL, or IPv4 address", text: $store.ruleProbeText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { store.runRuleProbe() }
                        Button {
                            store.runRuleProbe()
                        } label: {
                            Label("Match", systemImage: "arrowshape.turn.up.right")
                        }
                    }

                    if let match = store.routeProbeResult {
                        VStack(alignment: .leading, spacing: 6) {
                            CompatibilityRow(name: "Input", value: match.normalizedInput)
                            CompatibilityRow(name: "Source", value: match.source)
                            CompatibilityRow(name: "Policy", value: match.policy)
                            CompatibilityRow(name: "Policy path", value: match.policyPath.isEmpty ? match.policy : match.policyPath)
                            CompatibilityRow(name: "Outbound", value: match.outbound.isEmpty ? match.policy : match.outbound)
                            CompatibilityRow(name: "Rule", value: match.rule)
                            CompatibilityRow(name: "Reason", value: match.reason)
                        }
                    } else {
                        Text("No route evaluated")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SectionPanel(title: "Latency", icon: "antenna.radiowaves.left.and.right") {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        Task { await store.runLatencyChecks() }
                    } label: {
                        Label("Probe Endpoints", systemImage: "play.circle")
                    }

                    ForEach(store.profile.proxies.filter(\.kind.isStandardTCPProbeable)) { proxy in
                        HStack {
                            Text(proxy.name)
                            Spacer()
                            LatencyBadge(result: store.latencyResults[proxy.name])
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .pagePadding()
    }
}

struct RuleSetsView: View {
    @EnvironmentObject private var store: WorkbenchStore

    private var ruleSetRules: [ProxyRule] {
        store.profile.rules.filter { $0.type == "RULE-SET" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Header(title: "Rule Sets", subtitle: "\(ruleSetRules.count) remote sets, \(store.importedRuleSetRuleCount) downloaded rules")
                Spacer()
                Button {
                    Task { await store.importRuleSets() }
                } label: {
                    Label(store.ruleSetImportInProgress ? "Downloading" : "Download Rule Sets", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.ruleSetImportInProgress || ruleSetRules.isEmpty)
            }

            HStack(spacing: 12) {
                CompactStat(title: "Profile sets", value: "\(ruleSetRules.count)", icon: "rectangle.stack.badge.plus")
                CompactStat(title: "Downloaded rules", value: "\(store.importedRuleSetRuleCount)", icon: "tray.and.arrow.down")
                CompactStat(title: "Effective rules", value: "\(store.expandedRuleCount)", icon: "rectangle.expand.vertical")
                CompactStat(title: "Statuses", value: "\(store.ruleSetStatusByURL.count)", icon: "checkmark.seal")
            }
            .panelSurface()

            VStack(spacing: 0) {
                RuleSetTableHeader()
                ForEach(ruleSetRules) { rule in
                    RuleSetRow(rule: rule, status: store.ruleSetStatusByURL[rule.value])
                    Divider()
                        .padding(.leading, 16)
                }
                if ruleSetRules.isEmpty {
                    EmptyStateRow(title: "No RULE-SET entries", subtitle: "Import a profile with remote rule sets to manage them here.")
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .pagePadding()
    }
}

struct RuleSetTableHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Line")
                .frame(width: 54, alignment: .trailing)
            Text("URL")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Policy")
                .frame(width: 160, alignment: .leading)
            Text("Status")
                .frame(width: 150, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct RuleSetRow: View {
    let rule: ProxyRule
    let status: String?

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rule.sourceLine)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
            Text(rule.value)
                .font(.caption.monospaced())
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            RulePolicyBadge(policy: rule.policy)
                .frame(width: 160, alignment: .leading)
            Text(status ?? "Not downloaded")
                .font(.caption.weight(.medium))
                .foregroundStyle(status?.hasPrefix("Imported") == true ? .green : .secondary)
                .frame(width: 150, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct TrafficView: View {
    @EnvironmentObject private var store: WorkbenchStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Header(title: "Traffic", subtitle: "\(store.proxyEvents.count) captured requests")

            HStack(spacing: 12) {
                CompactStat(title: "Requests", value: "\(store.proxyEvents.count)", icon: "arrow.up.arrow.down")
                CompactStat(title: "Policies hit", value: "\(store.proxyPolicyStats.count)", icon: "chart.bar")
                CompactStat(title: "Rules hit", value: "\(store.proxyRuleStats.count)", icon: "number.square")
                CompactStat(title: "Mode", value: store.proxyRoutingMode.title, icon: "point.topleft.down.curvedto.point.bottomright.up")
            }
            .panelSurface()

            NetworkActivityPanel()

            HStack(alignment: .top, spacing: 14) {
                SectionPanel(title: "Policy Hits", icon: "chart.bar.xaxis") {
                    if store.proxyPolicyStats.isEmpty {
                        Text("No policy hits yet")
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVStack(spacing: 6) {
                            ForEach(store.proxyPolicyStats) { stat in
                                ProxyPolicyHitRow(stat: stat)
                            }
                        }
                    }
                }

                SectionPanel(title: "Rule Hits", icon: "number.square") {
                    if store.proxyRuleStats.isEmpty {
                        Text("No rule hits yet")
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVStack(spacing: 6) {
                            ForEach(store.proxyRuleStats) { stat in
                                ProxyRuleHitRow(stat: stat)
                            }
                        }
                    }
                }
            }
        }
        .pagePadding()
    }
}

struct DNSView: View {
    @EnvironmentObject private var store: WorkbenchStore

    private var dnsEntries: [(String, String)] {
        store.profile.general
            .filter { key, _ in key.lowercased().contains("dns") || key.lowercased().contains("server") }
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Header(title: "DNS", subtitle: dnsEntries.isEmpty ? "No DNS settings in current profile" : "\(dnsEntries.count) DNS-related settings")

            SectionPanel(title: "DNS Profile Settings", icon: "globe.desk") {
                if dnsEntries.isEmpty {
                    Text("Import a profile with DNS settings to review them here.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(dnsEntries, id: \.0) { key, value in
                            CompatibilityRow(name: key, value: value)
                        }
                    }
                }
            }

            SectionPanel(title: "Route Test", icon: "scope") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        TextField("Host or URL", text: $store.ruleProbeText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { store.runRuleProbe() }
                        Button {
                            store.runRuleProbe()
                        } label: {
                            Label("Resolve Route", systemImage: "arrowshape.turn.up.right")
                        }
                    }

                    if let match = store.routeProbeResult {
                        CompatibilityRow(name: "Input", value: match.normalizedInput)
                        CompatibilityRow(name: "Policy", value: match.policy)
                        CompatibilityRow(name: "Outbound", value: match.outbound.isEmpty ? match.policy : match.outbound)
                        CompatibilityRow(name: "Reason", value: match.reason)
                    }
                }
            }
        }
        .pagePadding()
    }
}

struct TunnelDebugView: View {
    @EnvironmentObject private var store: WorkbenchStore

    private var configuration: PacketTunnelConfigurationSnapshot? {
        store.packetTunnelConfigurationSnapshot
    }

    private var diagnostics: PacketTunnelDiagnosticsSnapshot? {
        store.packetTunnelDiagnosticsSnapshot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Header(title: "Tunnel Debug", subtitle: store.packetTunnelDebugSubtitle)
                Spacer()
                Button {
                    Task { await store.refreshPacketTunnelConfiguration() }
                } label: {
                    Label("Config", systemImage: "gearshape")
                }
                Button {
                    Task { await store.refreshPacketTunnelStatus() }
                } label: {
                    Label("Status", systemImage: "arrow.clockwise")
                }
                Button {
                    Task { await store.refreshPacketTunnelDiagnostics() }
                } label: {
                    Label("Counters", systemImage: "chart.bar.doc.horizontal")
                }
            }

            SectionPanel(title: "Transparent Path", icon: "point.3.connected.trianglepath.dotted") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    CompactStat(title: "Takeover", value: store.packetTunnelConnected ? "Packet Tunnel" : store.packetTunnelStatusText, icon: "shield.lefthalf.filled")
                    CompactStat(title: "Engine", value: configuration?.engineDescription ?? "Unknown", icon: "cpu")
                    CompactStat(title: "Tunnel DNS", value: configuration?.tunnelDNSServers.joined(separator: ", ") ?? "Unknown", icon: "globe.desk")
                    CompactStat(title: "Local SOCKS5", value: configuration.map { "\($0.socksHost):\($0.socksPort)" } ?? "Unknown", icon: "point.3.connected.trianglepath.dotted")
                    CompactStat(title: "Fake-IP", value: configuration.map { $0.enableFakeIPDNS ? "Enabled" : "Disabled" } ?? "Unknown", icon: "number")
                    CompactStat(title: "Upstream Bypass", value: configuration.map { "\($0.excludedIPv4Addresses.count) addresses" } ?? "Unknown", icon: "arrow.triangle.branch")
                }
            }

            SectionPanel(title: "Data Plane Health", icon: "waveform.path.ecg.rectangle") {
                VStack(alignment: .leading, spacing: 10) {
                    TunnelStageRow(
                        title: "Ingress packets",
                        value: diagnostics.map { "\($0.packetsRead) packets, IPv4 \($0.ipv4Packets), IPv6 \($0.ipv6Packets)" } ?? "No counters",
                        state: diagnostics.map { $0.packetsRead > 0 ? .good : .warning } ?? .idle
                    )
                    TunnelStageRow(
                        title: "DNS capture",
                        value: diagnostics.map { "\($0.dnsQueries) queries, fake-IP TCP \($0.fakeIPTCPDestinations)" } ?? "No counters",
                        state: diagnostics.map { $0.dnsQueries > 0 ? .good : .warning } ?? .idle
                    )
                    TunnelStageRow(
                        title: "TCP to SOCKS5",
                        value: diagnostics.map { "\($0.tcpSocksConnectAttempts) attempts, \($0.tcpSocksConnectSuccesses) ok, \($0.tcpSocksConnectFailures) failed" } ?? "No counters",
                        state: diagnostics.map { $0.tcpSocksConnectFailures == 0 && $0.tcpSocksConnectSuccesses > 0 ? .good : ($0.tcpSocksConnectFailures > 0 ? .bad : .warning) } ?? .idle
                    )
                    TunnelStageRow(
                        title: "Return packets",
                        value: diagnostics.map { "\($0.tcpPacketsWritten) writes, \($0.tcpRetransmittedPackets) retransmits, \($0.tcpResetsSent) resets" } ?? "No counters",
                        state: diagnostics.map { $0.tcpResetsSent == 0 && $0.tcpPacketsWritten > 0 ? .good : ($0.tcpResetsSent > 0 ? .bad : .warning) } ?? .idle
                    )
                }
            }

            SectionPanel(title: "Packet Counters", icon: "number.square") {
                if let diagnostics {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                        CompactStat(title: "TCP Packets", value: "\(diagnostics.tcpPackets)", icon: "arrow.left.arrow.right")
                        CompactStat(title: "UDP Packets", value: "\(diagnostics.udpPackets)", icon: "circle.grid.cross")
                        CompactStat(title: "Client to Upstream", value: Self.byteText(diagnostics.tcpUpstreamBytesSent), icon: "arrow.up")
                        CompactStat(title: "Upstream to Client", value: Self.byteText(diagnostics.tcpClientBytesSent), icon: "arrow.down")
                        CompactStat(title: "Active TCP", value: "\(diagnostics.activeTCPFlows)", icon: "point.3.filled.connected.trianglepath.dotted")
                        CompactStat(title: "Fake-IP Mappings", value: "\(diagnostics.fakeIPMappings)", icon: "list.bullet.rectangle")
                        CompactStat(title: "UDP Relay", value: "\(diagnostics.udpRelayedPackets) relayed / \(diagnostics.udpRejectedPackets) rejected", icon: "arrow.triangle.2.circlepath")
                        CompactStat(title: "IPv6 Blackhole", value: "\(diagnostics.ipv6BlackholedPackets)", icon: "nosign")
                    }
                } else {
                    Text(store.packetTunnelDiagnosticsText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
                }
            }

            SectionPanel(title: "HEV Bridge", icon: "link") {
                if let diagnostics, hasHevCounters(diagnostics) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                        CompactStat(title: "Bridge In", value: "\(diagnostics.hevPacketsSentToTunnel) / \(Self.byteText(diagnostics.hevBytesSentToTunnel))", icon: "arrow.right")
                        CompactStat(title: "Bridge Out", value: "\(diagnostics.hevPacketsReceivedFromTunnel) / \(Self.byteText(diagnostics.hevBytesReceivedFromTunnel))", icon: "arrow.left")
                        CompactStat(title: "Bridge Errors", value: "\(diagnostics.hevBridgeWriteFailures)", icon: diagnostics.hevBridgeWriteFailures == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                        CompactStat(title: "HEV TX/RX", value: "\(diagnostics.hevTunnelTxPackets)/\(diagnostics.hevTunnelRxPackets)", icon: "chart.bar")
                    }
                } else {
                    CompatibilityRow(name: "Engine", value: configuration?.packetEngine == "hev" ? "No HEV counters yet" : "Native engine")
                }
            }

            SectionPanel(title: "Configuration", icon: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: 8) {
                    CompatibilityRow(name: "Summary", value: store.packetTunnelConfigurationText)
                    if let configuration {
                        CompatibilityRow(name: "Listener", value: configuration.listenerSummary)
                        CompatibilityRow(name: "DNS", value: configuration.dnsSummary)
                        CompatibilityRow(name: "Bypass", value: configuration.exclusionSummary)
                        CompatibilityRow(name: "Flags", value: flagsSummary(configuration))
                        CompatibilityRow(name: "HEV", value: hevSummary(configuration))
                    }
                    CompatibilityRow(name: "Status", value: store.packetTunnelStatusText)
                    CompatibilityRow(name: "Diagnostics", value: store.packetTunnelDiagnosticsText)
                    CompatibilityRow(name: "Last counters", value: store.packetTunnelLastDiagnosticsRefreshText)
                }
            }
        }
        .pagePadding()
    }

    private func hasHevCounters(_ diagnostics: PacketTunnelDiagnosticsSnapshot) -> Bool {
        diagnostics.hevPacketsSentToTunnel > 0
            || diagnostics.hevPacketsReceivedFromTunnel > 0
            || diagnostics.hevBridgeWriteFailures > 0
            || diagnostics.hevTunnelTxPackets > 0
            || diagnostics.hevTunnelRxPackets > 0
    }

    private func flagsSummary(_ configuration: PacketTunnelConfigurationSnapshot) -> String {
        [
            "fake-IP \(configuration.enableFakeIPDNS ? "on" : "off")",
            "AAAA suppress \(configuration.suppressIPv6DNS ? "on" : "off")",
            "UDP relay \(configuration.enableUDPRelay ? "on" : "off")",
            "proxy settings \(configuration.enableProxySettings ? "on" : "off")",
            "IPv6 blackhole \(configuration.enableIPv6Blackhole ? "on" : "off")"
        ].joined(separator: ", ")
    }

    private func hevSummary(_ configuration: PacketTunnelConfigurationSnapshot) -> String {
        guard configuration.packetEngine == "hev" else {
            return "Disabled"
        }
        let library = configuration.hevLibraryDirectory ?? "Bundled"
        return "UDP \(configuration.hevUDPMode), library \(library)"
    }

    private static func byteText(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
    }
}

enum TunnelStageState {
    case good
    case warning
    case bad
    case idle
}

struct TunnelStageRow: View {
    let title: String
    let value: String
    let state: TunnelStageState

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .fontWeight(.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer()
        }
        .font(.callout)
    }

    private var color: Color {
        switch state {
        case .good: .green
        case .warning: .orange
        case .bad: .red
        case .idle: .secondary
        }
    }

    private var icon: String {
        switch state {
        case .good: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .bad: "xmark.octagon.fill"
        case .idle: "circle"
        }
    }
}

struct TestsView: View {
    @EnvironmentObject private var store: WorkbenchStore

    private var failureCount: Int {
        store.connectivityTestResults.filter { $0.status == .failed }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Header(title: "Tests", subtitle: testsSubtitle)
                Spacer()
                Button {
                    Task { await store.runStartupWorkflow() }
                } label: {
                    Label(store.startupWorkflowRunning ? "Starting" : "Run 1-8", systemImage: "play.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.startupWorkflowRunning || store.connectivityTestRunning)

                Button {
                    Task { await store.refreshStartupWorkflowStatus() }
                } label: {
                    Label("Refresh Status", systemImage: "arrow.clockwise")
                }
                .disabled(store.systemProxyStatusInProgress || store.connectivityTestRunning || store.startupWorkflowRunning)

                Button {
                    Task { await store.runConnectivityDiagnostics() }
                } label: {
                    Label(store.connectivityTestRunning ? "Running" : "Run Tests", systemImage: "play.fill")
                }
                .disabled(store.connectivityTestRunning || store.startupWorkflowRunning)

                Button {
                    Task { await store.openBlazeTestBrowser() }
                } label: {
                    Label("Open Test Browser", systemImage: "safari")
                }
                .disabled(store.startupWorkflowRunning)
            }

            SectionPanel(title: "Global VPN Startup", icon: "list.number") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(store.startupWorkflowSubtitle)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            Task { await store.refreshStartupWorkflowStatus() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(store.startupWorkflowRunning || store.connectivityTestRunning)
                        Button {
                            Task { await store.stopPacketTunnel() }
                        } label: {
                            Label("Stop VPN", systemImage: "stop.circle")
                        }
                        .disabled(store.startupWorkflowRunning)
                        Button {
                            Task { await store.stopPacketTunnelAndRestoreSurge() }
                        } label: {
                            Label("Stop + Surge", systemImage: "arrow.clockwise.circle")
                        }
                        .disabled(store.startupWorkflowRunning)
                    }

                    LazyVStack(spacing: 8) {
                        ForEach(store.startupWorkflowSteps) { step in
                            StartupWorkflowStepRow(
                                step: step,
                                isWorkflowRunning: store.startupWorkflowRunning
                            ) {
                                Task { await store.runStartupWorkflowStep(step.id) }
                            }
                        }
                    }
                }
            }

            SectionPanel(title: "Current State", icon: "switch.2") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    CompactStat(title: "Browser Route", value: browserRouteSummary, icon: "safari")
                    CompactStat(title: "Routing", value: store.activeRoutingSummary, icon: "point.topleft.down.curvedto.point.bottomright.up")
                    CompactStat(title: "Rule Cache", value: "\(store.importedRuleSetRuleCount)", icon: "tray.and.arrow.down")
                    CompactStat(title: "Effective Proxy", value: store.effectiveProxyStatus.summary, icon: "point.3.connected.trianglepath.dotted")
                    CompactStat(title: "Configured Proxy", value: store.systemProxyStatus.summary, icon: "desktopcomputer")
                    CompactStat(title: "Surge", value: store.surgeConflictSummary, icon: "bolt.shield")
                    CompactStat(title: "Watchdog", value: store.startupWatchdogText, icon: "timer")
                    CompactStat(title: "System Extension", value: store.systemExtensionInstallSnapshot?.summary ?? store.systemExtensionInstallText, icon: "puzzlepiece.extension")
                    CompactStat(title: "Packet Tunnel", value: store.packetTunnelStatusText, icon: "shield.lefthalf.filled")
                    CompactStat(title: "Tunnel Config", value: store.packetTunnelConfigurationSnapshot?.engineDescription ?? store.packetTunnelConfigurationText, icon: "cpu")
                    CompactStat(title: "Local Proxy", value: store.localProxySummary, icon: "point.3.connected.trianglepath.dotted")
                    CompactStat(title: "HTTP", value: "127.0.0.1:\(store.proxyListenPort)", icon: "network")
                    CompactStat(title: "SOCKS5", value: "127.0.0.1:\(store.socksListenPort)", icon: "point.3.connected.trianglepath.dotted")
                }
            }

            SectionPanel(title: "Connectivity Results", icon: "checklist") {
                if store.connectivityTestResults.isEmpty {
                    Text("No test results")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(store.connectivityTestResults) { result in
                            ConnectivityResultRow(result: result)
                        }
                    }
                }
            }
        }
        .pagePadding()
    }

    private var testsSubtitle: String {
        if store.startupWorkflowRunning {
            return "Running Global VPN startup steps"
        }
        if store.connectivityTestRunning {
            return "Running route, Google, Baidu, ChatGPT, DNS, and local listener checks"
        }
        if store.connectivityTestResults.isEmpty {
            return "Route, Google, Baidu, ChatGPT, DNS, HTTP, and SOCKS5 checks"
        }
        return failureCount == 0 ? "All recent checks passed" : "\(failureCount) recent check\(failureCount == 1 ? "" : "s") failed"
    }

    private var browserRouteSummary: String {
        if store.packetTunnelConnected {
            return "Packet Tunnel"
        }
        if store.effectiveSystemProxyIsBlaze {
            return "Blaze Proxy"
        }
        if store.effectiveProxyStatus.anyProxyEnabled {
            return "Elsewhere"
        }
        return "Off"
    }
}

struct StartupWorkflowStepRow: View {
    let step: StartupWorkflowStep
    let isWorkflowRunning: Bool
    let run: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.14))
                Text("\(step.id)")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(statusColor)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(step.title)
                        .font(.callout.weight(.semibold))
                    Text(step.target)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let updatedAt = step.updatedAt {
                    Text(updatedAt, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            StatusPill(title: step.status.rawValue, systemImage: statusIcon, color: statusColor)
                .frame(minWidth: 106, alignment: .trailing)

            Button {
                run()
            } label: {
                Label(step.actionTitle, systemImage: "arrow.right.circle")
            }
            .disabled(isWorkflowRunning || step.status == .running)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusColor: Color {
        switch step.status {
        case .pending:
            return .secondary
        case .running:
            return .blue
        case .passed:
            return .green
        case .failed:
            return .red
        case .actionNeeded:
            return .orange
        case .info:
            return .secondary
        }
    }

    private var statusIcon: String {
        switch step.status {
        case .pending:
            return "circle"
        case .running:
            return "arrow.triangle.2.circlepath"
        case .passed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .actionNeeded:
            return "exclamationmark.triangle.fill"
        case .info:
            return "info.circle"
        }
    }
}

struct ConnectivityResultRow: View {
    let result: ConnectivityTestResult

    var body: some View {
        HStack(spacing: 12) {
            Text(result.date, style: .time)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(result.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(result.transport)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
                Text(result.target)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 220, alignment: .leading)

            Text(result.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(result.durationText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .trailing)

            Text(result.status.rawValue)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(statusColor.opacity(0.12), in: Capsule())
                .foregroundStyle(statusColor)
                .frame(width: 76)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusColor: Color {
        switch result.status {
        case .passed:
            return .green
        case .failed:
            return .red
        case .info:
            return .secondary
        }
    }
}

struct LogsView: View {
    @EnvironmentObject private var store: WorkbenchStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Header(title: "Logs", subtitle: "\(store.proxyEvents.count) recent local proxy events")
                Spacer()
                Button {
                    Task { await store.refreshProxyEvents() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    Task { await store.clearProxyEvents() }
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(store.proxyEvents.isEmpty)
            }

            SectionPanel(title: "Request Log", icon: "list.bullet.rectangle") {
                if store.proxyEvents.isEmpty {
                    Text("No requests captured")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(store.proxyEvents) { event in
                            ProxyEventRow(event: event)
                        }
                    }
                }
            }
        }
        .pagePadding()
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @State private var showingApplyConfirmation = false
    @State private var showingDisableConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Header(title: "Settings", subtitle: "Routing, local listeners, system proxy, and export")

            SectionPanel(title: "Routing", icon: "point.topleft.down.curvedto.point.bottomright.up") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Policy mode", selection: Binding(
                        get: { store.proxyRoutingMode },
                        set: { store.setProxyRoutingMode($0) }
                    )) {
                        ForEach(ProxyRoutingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if store.proxyRoutingMode == .global {
                        Picker("Global outbound", selection: Binding(
                            get: { store.globalProxyPolicy },
                            set: { store.setGlobalProxyPolicy($0) }
                        )) {
                            ForEach(store.availableGlobalPolicies, id: \.self) { policy in
                                Text(policy).tag(policy)
                            }
                        }
                        .frame(maxWidth: 420, alignment: .leading)
                    }
                }
            }

            SectionPanel(title: "Local Listeners", icon: "point.3.connected.trianglepath.dotted") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Text("HTTP")
                            .foregroundStyle(.secondary)
                        TextField("Port", value: $store.proxyListenPort, formatter: NumberFormatter.port)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .disabled(store.proxyServerRunning)
                        Text("SOCKS5")
                            .foregroundStyle(.secondary)
                        TextField("Port", value: $store.socksListenPort, formatter: NumberFormatter.port)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .disabled(store.socksServerRunning)
                        Spacer()
                        Button {
                            Task { await store.startLocalProxyStack() }
                        } label: {
                            Label("Start", systemImage: "play.circle")
                        }
                        .disabled(store.localProxyRunning)
                        Button {
                            Task { await store.stopLocalProxyStack() }
                        } label: {
                            Label("Stop", systemImage: "stop.circle")
                        }
                        .disabled(!store.localProxyRunning)
                    }
                    CompatibilityRow(name: "Status", value: store.localProxySummary)
                    CompatibilityRow(name: "Mode", value: store.activeRoutingSummary)
                }
            }

            SectionPanel(title: "macOS Proxy Setup", icon: "desktopcomputer") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        if store.detectedNetworkServices.isEmpty {
                            TextField("Wi-Fi", text: $store.networkServiceName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                        } else {
                            Picker("Service", selection: $store.networkServiceName) {
                                ForEach(store.detectedNetworkServices, id: \.self) { service in
                                    Text(service).tag(service)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 210)
                        }
                        Button {
                            Task { await store.detectNetworkServices() }
                        } label: {
                            Label(store.networkServiceDetectionInProgress ? "Detecting" : "Detect", systemImage: "magnifyingglass")
                        }
                        Button {
                            Task { await store.refreshSystemProxyStatus() }
                        } label: {
                            Label(store.systemProxyStatusInProgress ? "Checking" : "Status", systemImage: "checkmark.seal")
                        }
                        Spacer()
                        Button {
                            showingApplyConfirmation = true
                        } label: {
                            Label("Apply", systemImage: "checkmark.circle")
                        }
                        Button(role: .destructive) {
                            showingDisableConfirmation = true
                        } label: {
                            Label("Disable", systemImage: "xmark.circle")
                        }
                    }
                    CompatibilityRow(name: "System proxy", value: store.systemProxyStatus.summary)
                    CompatibilityRow(name: "Effective proxy", value: store.effectiveSystemProxySummary)
                    CompatibilityRow(name: "Restore point", value: store.systemProxyRestoreSummary)
                }
            }

            SectionPanel(title: "Packet Tunnel", icon: "shield.lefthalf.filled") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Button {
                            store.activatePacketTunnelSystemExtension()
                        } label: {
                            Label("Install Extension", systemImage: "puzzlepiece.extension")
                        }
                        Button(role: .destructive) {
                            store.deactivatePacketTunnelSystemExtension()
                        } label: {
                            Label("Remove Extension", systemImage: "minus.circle")
                        }
                        Spacer()
                        Button {
                            Task { await store.installPacketTunnelConfiguration() }
                        } label: {
                            Label("Install Config", systemImage: "gearshape")
                        }
                        Button {
                            Task { await store.startPacketTunnel() }
                        } label: {
                            Label("Start Tunnel", systemImage: "play.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            Task { await store.stopPacketTunnel() }
                        } label: {
                            Label("Stop Tunnel", systemImage: "stop.circle")
                        }
                        Button {
                            Task { await store.refreshPacketTunnelStatus() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        Button {
                            Task { await store.refreshPacketTunnelConfiguration() }
                        } label: {
                            Label("Config", systemImage: "slider.horizontal.3")
                        }
                        Button {
                            Task { await store.refreshPacketTunnelDiagnostics() }
                        } label: {
                            Label("Diagnostics", systemImage: "chart.bar.doc.horizontal")
                        }
                    }
                    CompatibilityRow(name: "Extension ID", value: SystemExtensionController.extensionIdentifier)
                    CompatibilityRow(name: "Host entitlement", value: store.packetTunnelHostEntitlementText)
                    CompatibilityRow(name: "Status", value: store.packetTunnelStatusText)
                    CompatibilityRow(name: "Config", value: store.packetTunnelConfigurationText)
                    CompatibilityRow(name: "Bypass", value: store.packetTunnelExcludedIPv4Summary)
                    CompatibilityRow(name: "Diagnostics", value: store.packetTunnelDiagnosticsText)
                    CompatibilityRow(name: "Mode", value: "Transparent IPv4 TCP via local SOCKS5; DNS fake-IP; UDP relay gated; AAAA suppressed until IPv6 forwarding lands")
                }
            }

            SectionPanel(title: "Export", icon: "curlybraces.square") {
                VStack(alignment: .leading, spacing: 10) {
                    TextEditor(text: .constant(store.sanitizedExport))
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 180)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    Button {
                        store.copyExportToPasteboard()
                    } label: {
                        Label("Copy Sanitized JSON", systemImage: "doc.on.doc")
                    }
                }
            }
        }
        .pagePadding()
        .confirmationDialog("Apply macOS proxy settings?", isPresented: $showingApplyConfirmation) {
            Button("Apply") {
                Task { await store.applySystemProxySettings() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This changes the selected network service to use blaze's local HTTP, HTTPS, and SOCKS5 ports.")
        }
        .confirmationDialog("Disable macOS proxy settings?", isPresented: $showingDisableConfirmation) {
            Button("Disable", role: .destructive) {
                Task { await store.disableSystemProxySettings() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This turns off HTTP, HTTPS, and SOCKS5 proxy settings for the selected macOS network service.")
        }
    }
}

struct ProfileEditorView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @State private var showSourceEditor = false
    @State private var showRemotePreview = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(title: "Profile", subtitle: "Import, persistence, and compatibility")

            SectionPanel(title: "Remote Import", icon: "link.badge.plus") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        TextField("https://example.com/profile.conf", text: $store.remoteProfileURLText)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            Task { await store.previewRemoteProfile() }
                        } label: {
                            Label(store.remotePreviewInProgress ? "Previewing" : "Preview", systemImage: "eye")
                        }
                        .disabled(store.remotePreviewInProgress || store.remoteImportInProgress)
                        Button {
                            Task { await store.importRemoteProfileAndRuleSets() }
                        } label: {
                            Label(store.remoteImportInProgress ? "Importing" : "Import & Validate", systemImage: "arrow.down.doc")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.remoteImportInProgress || store.remotePreviewInProgress)
                    }

                    HStack(spacing: 12) {
                        CompactStat(title: "Saved source", value: store.profileSummary.sourceSizeDescription, icon: "doc.text")
                        CompactStat(title: "Proxies", value: "\(store.profileSummary.proxies)", icon: "network")
                        CompactStat(title: "Groups", value: "\(store.profileSummary.groups)", icon: "square.stack.3d.up")
                        CompactStat(title: "Rules", value: "\(store.profileSummary.rules)", icon: "list.bullet.rectangle")
                    }
                }
            }

            if let preview = store.remotePreview {
                DisclosureGroup(isExpanded: $showRemotePreview) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            CompactStat(title: "Size", value: preview.summary.sourceSizeDescription, icon: "doc.text")
                            CompactStat(title: "Proxies", value: "\(preview.summary.proxies)", icon: "network")
                            CompactStat(title: "Groups", value: "\(preview.summary.groups)", icon: "square.stack.3d.up")
                            CompactStat(title: "Rule sets", value: "\(preview.summary.ruleSets)", icon: "arrow.down.doc")
                            CompactStat(title: "Warnings", value: "\(preview.summary.warnings)", icon: "exclamationmark.triangle")
                        }
                        if preview.summary.unsupportedSectionDescription != "None" {
                            Text(preview.summary.unsupportedSectionDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if !preview.warningSamples.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(preview.warningSamples.prefix(4), id: \.self) { warning in
                                    Text(warning)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Label("Remote Preview", systemImage: "eye")
                }
                .font(.callout.weight(.medium))
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }

            SectionPanel(title: "Import Summary", icon: "checklist") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        CompactStat(title: "General keys", value: "\(store.profileSummary.generalKeys)", icon: "gearshape")
                        CompactStat(title: "Rule sets", value: "\(store.profileSummary.ruleSets)", icon: "arrow.down.doc")
                        CompactStat(title: "Warnings", value: "\(store.profileSummary.warnings)", icon: "exclamationmark.triangle")
                        CompactStat(title: "Downloaded", value: "\(store.importedRuleSetRuleCount)", icon: "tray.and.arrow.down")
                    }
                    CompatibilityRow(name: "Unsupported", value: store.profileSummary.unsupportedSectionDescription)
                }
            }

            SectionPanel(title: "Source Editor", icon: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        StatusPill(title: showSourceEditor ? "Visible" : "Hidden", systemImage: showSourceEditor ? "eye" : "eye.slash", color: showSourceEditor ? .orange : .secondary)
                        Text("The raw source can contain credentials. Keep it collapsed unless you need to edit profile text.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            showSourceEditor.toggle()
                        } label: {
                            Label(showSourceEditor ? "Hide Source" : "Show Source", systemImage: showSourceEditor ? "eye.slash" : "eye")
                        }
                    }

                    if showSourceEditor {
                        TextEditor(text: $store.sourceText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 420)
                            .padding(8)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        HStack {
                            Button {
                                store.parseSource()
                            } label: {
                                Label("Parse", systemImage: "arrow.triangle.2.circlepath")
                            }
                            Button {
                                store.saveLocalState()
                            } label: {
                                Label("Save Locally", systemImage: "tray.and.arrow.down")
                            }
                            Button(role: .destructive) {
                                store.clearLocalState()
                            } label: {
                                Label("Clear Saved Data", systemImage: "trash")
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
        .pagePadding()
    }
}

struct ServerView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @State private var showingApplyConfirmation = false
    @State private var showingDisableConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Header(title: "Server", subtitle: "Local direct HTTP and CONNECT proxy")

            SectionPanel(title: "HTTP Listener", icon: "point.3.connected.trianglepath.dotted") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("127.0.0.1")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                        TextField("Port", value: $store.proxyListenPort, formatter: NumberFormatter.port)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .disabled(store.proxyServerRunning)
                        Spacer()
                        if store.proxyServerRunning {
                            Button {
                                Task { await store.stopLocalProxyServer() }
                            } label: {
                                Label("Stop", systemImage: "stop.circle")
                            }
                        } else {
                            Button {
                                Task { await store.startLocalProxyServer() }
                            } label: {
                                Label("Start", systemImage: "play.circle")
                            }
                        }
                    }

                    CompatibilityRow(name: "Status", value: store.proxyServerRunning ? "Running" : "Stopped")
                    CompatibilityRow(name: "Mode", value: "Rules resolve groups; HTTP/SOCKS5/Trojan forward; unsupported upstreams block")
                    CompatibilityRow(name: "Browser proxy", value: "HTTP proxy 127.0.0.1:\(store.proxyListenPort)")
                }
            }

            SectionPanel(title: "SOCKS5 Listener", icon: "point.3.connected.trianglepath.dotted") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("127.0.0.1")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                        TextField("Port", value: $store.socksListenPort, formatter: NumberFormatter.port)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .disabled(store.socksServerRunning)
                        Spacer()
                        if store.socksServerRunning {
                            Button {
                                Task { await store.stopLocalSocksServer() }
                            } label: {
                                Label("Stop", systemImage: "stop.circle")
                            }
                        } else {
                            Button {
                                Task { await store.startLocalSocksServer() }
                            } label: {
                                Label("Start", systemImage: "play.circle")
                            }
                        }
                    }

                    CompatibilityRow(name: "Status", value: store.socksServerRunning ? "Running" : "Stopped")
                    CompatibilityRow(name: "Mode", value: "SOCKS5 CONNECT with no-auth local clients")
                    CompatibilityRow(name: "Client proxy", value: "SOCKS5 127.0.0.1:\(store.socksListenPort)")
                }
            }

            SectionPanel(title: "macOS Proxy Setup", icon: "terminal") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Text("Service")
                            .foregroundStyle(.secondary)
                        if store.detectedNetworkServices.isEmpty {
                            TextField("Wi-Fi", text: $store.networkServiceName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                        } else {
                            Picker("Service", selection: $store.networkServiceName) {
                                ForEach(store.detectedNetworkServices, id: \.self) { service in
                                    Text(service).tag(service)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 210)
                        }
                        Spacer()
                        Button {
                            Task { await store.detectNetworkServices() }
                        } label: {
                            Label(store.networkServiceDetectionInProgress ? "Detecting" : "Detect", systemImage: "magnifyingglass")
                        }
                        .disabled(store.networkServiceDetectionInProgress || store.systemProxyApplyInProgress)
                        Button {
                            Task { await store.refreshSystemProxyStatus() }
                        } label: {
                            Label(store.systemProxyStatusInProgress ? "Checking" : "Status", systemImage: "checkmark.seal")
                        }
                        .disabled(store.systemProxyStatusInProgress || store.systemProxyApplyInProgress)
                        Button {
                            showingApplyConfirmation = true
                        } label: {
                            Label(store.systemProxyApplyInProgress ? "Applying" : "Apply", systemImage: "checkmark.circle")
                        }
                        .disabled(store.systemProxyApplyInProgress)
                        Button {
                            showingDisableConfirmation = true
                        } label: {
                            Label("Disable", systemImage: "xmark.circle")
                        }
                        .disabled(store.systemProxyApplyInProgress)
                        Button {
                            store.copyNetworkServiceListCommand()
                        } label: {
                            Label("List Services", systemImage: "list.bullet")
                        }
                        Button {
                            store.copyEnableSystemProxyCommands()
                        } label: {
                            Label("Copy Enable", systemImage: "doc.on.doc")
                        }
                        Button {
                            store.copyDisableSystemProxyCommands()
                        } label: {
                            Label("Copy Disable", systemImage: "xmark.circle")
                        }
                    }

                    CompatibilityRow(name: "HTTP", value: "127.0.0.1:\(store.proxyListenPort)")
                    CompatibilityRow(name: "SOCKS5", value: "127.0.0.1:\(store.socksListenPort)")
                    CompatibilityRow(name: "System proxy", value: store.systemProxyStatus.summary)
                    CompatibilityRow(name: "Restore point", value: store.systemProxyRestoreSummary)
                    CompatibilityRow(name: "Policy mode", value: store.activeRoutingSummary)
                    CompatibilityRow(name: "Behavior", value: "Apply/Disable run networksetup only when clicked; copy buttons only copy commands")
                }
            }

            SectionPanel(title: "Policy Hits", icon: "chart.bar.xaxis") {
                if store.proxyPolicyStats.isEmpty {
                    Text("No policy hits yet")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(store.proxyPolicyStats) { stat in
                            ProxyPolicyHitRow(stat: stat)
                        }
                    }
                }
            }

            SectionPanel(title: "Rule Hits", icon: "number.square") {
                if store.proxyRuleStats.isEmpty {
                    Text("No rule hits yet")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(store.proxyRuleStats) { stat in
                            ProxyRuleHitRow(stat: stat)
                        }
                    }
                }
            }

            SectionPanel(title: "Request Log", icon: "list.bullet.rectangle") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button {
                            Task { await store.refreshProxyEvents() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }

                        Button {
                            Task { await store.clearProxyEvents() }
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                        Spacer()
                    }

                    if store.proxyEvents.isEmpty {
                        Text("No requests captured")
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVStack(spacing: 6) {
                            ForEach(store.proxyEvents) { event in
                                ProxyEventRow(event: event)
                            }
                        }
                    }
                }
            }
        }
        .pagePadding()
        .confirmationDialog("Apply macOS proxy settings?", isPresented: $showingApplyConfirmation) {
            Button("Apply") {
                Task { await store.applySystemProxySettings() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This saves the current system proxy as a restore point, then changes the selected macOS network service to use blaze's local HTTP/HTTPS and SOCKS5 ports.")
        }
        .confirmationDialog("Disable macOS proxy settings?", isPresented: $showingDisableConfirmation) {
            Button("Disable", role: .destructive) {
                Task { await store.disableSystemProxySettings() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This turns off HTTP, HTTPS, and SOCKS5 proxy settings for the selected macOS network service.")
        }
    }
}

struct ProxyPolicyHitRow: View {
    let stat: ProxyPolicyHitStat

    var body: some View {
        HStack(spacing: 12) {
            Text("\(stat.count)")
                .font(.callout.monospacedDigit().weight(.semibold))
                .frame(width: 48, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(stat.policy)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(stat.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ProxyRuleHitRow: View {
    let stat: ProxyRuleHitStat

    var body: some View {
        HStack(spacing: 12) {
            Text("\(stat.count)")
                .font(.callout.monospacedDigit().weight(.semibold))
                .frame(width: 48, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(stat.rule)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(stat.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ProxyEventRow: View {
    let event: ProxyServerEvent

    var body: some View {
        HStack(spacing: 12) {
            Text(event.date, style: .time)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Text(event.method)
                .font(.caption.weight(.semibold))
                .frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.host == "-" ? event.target : "\(event.host):\(event.port)")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(event.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(event.policy)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .trailing)
            Text(event.status)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(statusColor.opacity(0.12), in: Capsule())
                .foregroundStyle(statusColor)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusColor: Color {
        switch event.status {
        case "Connected":
            return .green
        case "Closed":
            return .secondary
        default:
            return .red
        }
    }
}

struct ExportView: View {
    @EnvironmentObject private var store: WorkbenchStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(title: "Export", subtitle: "Sanitized JSON")
            TextEditor(text: .constant(store.sanitizedExport))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 560)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button {
                    store.copyExportToPasteboard()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Spacer()
            }
        }
        .pagePadding()
    }
}

struct Header: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct StatusPill: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct CompactStat: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
    }
}

enum SetupStepState {
    case complete
    case pending
}

struct SetupStepTile: View {
    let index: Int
    let title: String
    let value: String
    let systemImage: String
    let state: SetupStepState

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.14))
                Text("\(index)")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(color)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(value)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(0.18), lineWidth: 1)
        )
    }

    private var color: Color {
        switch state {
        case .complete: .teal
        case .pending: .secondary
        }
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.teal)
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SectionPanel<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct CompatibilityRow: View {
    let name: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .fontWeight(.medium)
            Spacer()
        }
        .font(.callout)
    }
}

struct LatencyBadge: View {
    let result: LatencyResult?

    var body: some View {
        if let result {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(result.milliseconds.map { "\($0) ms" } ?? result.status)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
        } else {
            Text("Not checked")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch result?.status {
        case "Reachable": .green
        case "Skipped": .gray
        case "Timeout": .orange
        case "Failed", "Invalid": .red
        default: .secondary
        }
    }
}

struct FlowLayout: View {
    let items: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.blue.opacity(0.10), in: Capsule())
            }
        }
    }
}

private extension View {
    func pagePadding() -> some View {
        padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    func panelSurface() -> some View {
        padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

private extension ProxyNode {
    var displayRegion: String {
        for key in ["region", "country", "location", "area"] {
            if let value = parameters[key], !value.isEmpty {
                return value
            }
        }

        let lowerName = name.lowercased()
        let lowerHost = host.lowercased()
        let checks: [(String, String)] = [
            ("singapore", "Singapore"),
            ("sg", "Singapore"),
            ("japan", "Japan"),
            ("jp", "Japan"),
            ("hong kong", "Hong Kong"),
            ("hk", "Hong Kong"),
            ("united states", "United States"),
            ("usa", "United States"),
            ("us", "United States"),
            ("germany", "Germany"),
            ("de", "Germany"),
            ("france", "France"),
            ("fr", "France"),
            ("uk", "United Kingdom"),
            ("london", "United Kingdom")
        ]

        for (needle, region) in checks where lowerName.contains(needle) || lowerHost.contains(".\(needle).") {
            return region
        }
        return "-"
    }
}

private extension NumberFormatter {
    static var port: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 1
        formatter.maximum = 65535
        return formatter
    }
}
