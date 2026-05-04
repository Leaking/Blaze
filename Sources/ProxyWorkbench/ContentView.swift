import ProxyWorkbenchCore
import SwiftUI
import UniformTypeIdentifiers

enum WorkbenchSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case proxies = "Proxies"
    case groups = "Groups"
    case rules = "Rules"
    case tester = "Tester"
    case server = "Server"
    case editor = "Profile"
    case export = "Export"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .proxies: "network"
        case .groups: "square.stack.3d.up"
        case .rules: "list.bullet.rectangle"
        case .tester: "scope"
        case .server: "point.3.connected.trianglepath.dotted"
        case .editor: "doc.text"
        case .export: "curlybraces.square"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @State private var selection: WorkbenchSection? = .overview
    @State private var importing = false
    @State private var showingCommandPalette = false

    var body: some View {
        NavigationSplitView {
            List(WorkbenchSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
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
                            importing = true
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
            WorkbenchCommand(title: "Go to Groups", subtitle: "\(store.profile.groups.count) groups", systemImage: WorkbenchSection.groups.icon, keywords: "group select policy") {
                selection = .groups
            },
            WorkbenchCommand(title: "Go to Rules", subtitle: "\(store.profile.rules.count) rules", systemImage: WorkbenchSection.rules.icon, keywords: "rule ruleset route") {
                selection = .rules
            },
            WorkbenchCommand(title: "Go to Tester", subtitle: "Explain rule matches and outbound", systemImage: WorkbenchSection.tester.icon, keywords: "tester route match") {
                selection = .tester
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
            pendingSystemAction == .stop ? "Stop Proxy Workbench?" : "Start Proxy Workbench?",
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
                Text("This saves the current macOS proxy settings, starts local listeners, and changes the selected network service to Proxy Workbench's local ports.")
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
                case .groups:
                    GroupsView()
                case .rules:
                    RulesView()
                case .tester:
                    TesterView()
                case .server:
                    ServerView()
                case .editor:
                    ProfileEditorView()
                case .export:
                    ExportView()
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
            Header(title: "Proxy Workbench", subtitle: store.activeRoutingSummary)

            HStack(alignment: .top, spacing: 16) {
                LaunchPanel(
                    onStart: { showingStartConfirmation = true },
                    onStop: { showingStopConfirmation = true }
                )
                .frame(minWidth: 480)

                QuickImportPanel()
                    .frame(minWidth: 360)
            }

            SetupProgressStrip()

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                MetricTile(title: "Proxies", value: "\(store.profile.proxies.count)", icon: "network")
                MetricTile(title: "Groups", value: "\(store.profile.groups.count)", icon: "square.stack.3d.up")
                MetricTile(title: "Rules", value: "\(store.profile.rules.count)", icon: "list.bullet.rectangle")
                MetricTile(title: "Warnings", value: "\(store.profile.warnings.count)", icon: "exclamationmark.triangle")
            }

            HStack(alignment: .top, spacing: 16) {
                SectionPanel(title: "Profile Health", icon: "checklist") {
                    CompatibilityRow(name: "Profile sections", value: "General, Proxy, Proxy Group, Rule")
                    CompatibilityRow(name: "Rule decisions", value: "DOMAIN, DOMAIN-SUFFIX, DOMAIN-KEYWORD, DOMAIN-WILDCARD, URL-REGEX, IP-CIDR, IP-CIDR6, DEST-PORT, FINAL")
                    CompatibilityRow(name: "Rule-set cache", value: "\(store.importedRuleSetRuleCount) downloaded rules")
                    CompatibilityRow(name: "Preserved sections", value: store.profile.unsupportedSectionNames.isEmpty ? "None" : store.profile.unsupportedSectionNames.joined(separator: ", "))
                }

                SectionPanel(title: "Warnings", icon: "exclamationmark.triangle") {
                    if store.profile.warnings.isEmpty {
                        Text("None")
                            .font(.callout.weight(.medium))
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(store.profile.warnings.prefix(6)) { warning in
                                HStack(alignment: .firstTextBaseline) {
                                    Text("L\(warning.line)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 44, alignment: .leading)
                                    Text(warning.message)
                                        .font(.callout)
                                        .lineLimit(2)
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            }
        }
        .pagePadding()
        .confirmationDialog("Start Proxy Workbench?", isPresented: $showingStartConfirmation) {
            Button("Start Proxy") {
                Task { await store.startAndApplySystemProxy() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This saves the current system proxy as a restore point, starts local listeners, and changes the selected macOS network service to use 127.0.0.1:\(store.proxyListenPort) for HTTP/HTTPS and 127.0.0.1:\(store.socksListenPort) for SOCKS5.")
        }
        .confirmationDialog("Stop Proxy Workbench?", isPresented: $showingStopConfirmation) {
            Button("Stop Proxy", role: .destructive) {
                Task { await store.disableSystemProxyAndStop() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This stops local listeners and restores the saved system proxy settings when available. If no restore point exists, it only disables system proxy settings that currently point to Proxy Workbench's local ports.")
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
    @State private var quickProxyKind = "http"
    @State private var quickProxyName = ""
    @State private var quickProxyHost = ""
    @State private var quickProxyPort = ""
    @State private var quickProxyUsername = ""
    @State private var quickProxyPassword = ""

    private let quickProxyKinds = ["http", "https", "socks5", "trojan"]

    private var filteredProxies: [ProxyNode] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return store.profile.proxies }
        return store.profile.proxies.filter { proxy in
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Header(title: "Policy", subtitle: store.proxyRoutingMode.subtitle)

            Picker("Proxy mode", selection: Binding(
                get: { store.proxyRoutingMode },
                set: { store.setProxyRoutingMode($0) }
            )) {
                ForEach(ProxyRoutingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 780)

            if store.proxyRoutingMode == .global {
                HStack(spacing: 10) {
                    Text("Global outbound")
                        .foregroundStyle(.secondary)
                    Picker("Global outbound", selection: Binding(
                        get: { store.globalProxyPolicy },
                        set: { store.setGlobalProxyPolicy($0) }
                    )) {
                        ForEach(store.availableGlobalPolicies, id: \.self) { policy in
                            Text(policy).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 420, alignment: .leading)
                    Spacer()
                }
            }

            HStack(spacing: 12) {
                SearchField(text: $searchText, placeholder: "Filter by name, protocol, host, port, or parameter")
                    .frame(maxWidth: 560)
                Toggle("Reveal secrets", isOn: $store.revealSecrets)
                    .toggleStyle(.switch)
                Spacer()
            }

            SectionPanel(title: "Quick Add Proxy", icon: "plus.circle") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Picker("Protocol", selection: $quickProxyKind) {
                            ForEach(quickProxyKinds, id: \.self) { kind in
                                Text(kind.uppercased()).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)

                        TextField("Proxy name", text: $quickProxyName)
                            .textFieldStyle(.roundedBorder)

                        TextField("Host", text: $quickProxyHost)
                            .textFieldStyle(.roundedBorder)

                        TextField("Port", text: $quickProxyPort)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                    }

                    HStack(spacing: 10) {
                        TextField(quickProxyKind == "trojan" ? "Username not used" : "Username optional", text: $quickProxyUsername)
                            .textFieldStyle(.roundedBorder)
                            .disabled(quickProxyKind == "trojan")
                            .frame(maxWidth: 260)

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
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("PROXY")
                        .font(.headline)
                        .foregroundStyle(.purple)
                    Text(searchText.isEmpty ? "\(store.profile.proxies.count)" : "\(filteredProxies.count) of \(store.profile.proxies.count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await store.runLatencyChecks() }
                    } label: {
                        Label("Test All", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(store.profile.proxies.isEmpty)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 310), spacing: 14)], spacing: 14) {
                    ForEach(filteredProxies) { proxy in
                        ProxyCard(
                            proxy: proxy,
                            result: store.latencyResults[proxy.name],
                            revealSecrets: store.revealSecrets,
                            isSelected: store.proxyRoutingMode == .global && store.globalProxyPolicy == proxy.name,
                            showsSelect: store.proxyRoutingMode == .global,
                            onSelect: {
                                store.setGlobalProxyPolicy(proxy.name)
                            }
                        ) {
                            Task { await store.runLatencyCheck(proxyName: proxy.name) }
                        }
                    }
                }
            }
        }
        .pagePadding()
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

struct RulesView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @State private var searchText = ""
    @State private var scope: RuleScope = .all
    @State private var showRuleSetStatus = false
    @State private var quickRuleType = "DOMAIN-SUFFIX"
    @State private var quickRuleValue = ""
    @State private var quickRulePolicy = ""
    @State private var pendingRuleRemoval: ProxyRule?

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
        }
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

            HStack(spacing: 12) {
                CompactStat(title: "Profile rules", value: "\(store.profile.rules.count)", icon: "list.bullet.rectangle")
                CompactStat(title: "RULE-SET", value: "\(store.profileSummary.ruleSets)", icon: "arrow.down.doc")
                CompactStat(title: "Expanded", value: "\(store.expandedRuleCount)", icon: "rectangle.expand.vertical")
                CompactStat(title: "Downloaded", value: "\(store.importedRuleSetRuleCount)", icon: "tray.and.arrow.down")
                Button {
                    Task { await store.importRuleSets() }
                } label: {
                    Label(store.ruleSetImportInProgress ? "Loading" : "Download", systemImage: "arrow.down.circle")
                }
                .disabled(store.ruleSetImportInProgress)
            }
            .panelSurface()

            SectionPanel(title: "Quick Add Rule", icon: "plus.circle") {
                HStack(spacing: 10) {
                    Picker("Type", selection: $quickRuleType) {
                        ForEach(quickRuleTypes, id: \.self) { type in
                            Text(type).tag(type)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)

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
                    .frame(width: 240)

                    Button {
                        store.addRule(type: quickRuleType, value: quickRuleValue, policy: quickRulePolicy)
                        quickRuleValue = ""
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(quickRuleValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || quickRulePolicy.isEmpty)
                }
            }

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
                    RuleTableRow(rule: rule) {
                        pendingRuleRemoval = rule
                    }
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
    let onRemove: () -> Void

    var body: some View {
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
            Text("This saves the current system proxy as a restore point, then changes the selected macOS network service to use Proxy Workbench's local HTTP/HTTPS and SOCKS5 ports.")
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
                    .lineLimit(1)
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
                .background(event.status == "Connected" ? Color.green.opacity(0.12) : Color.red.opacity(0.12), in: Capsule())
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
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

private extension NumberFormatter {
    static var port: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 1
        formatter.maximum = 65535
        return formatter
    }
}
