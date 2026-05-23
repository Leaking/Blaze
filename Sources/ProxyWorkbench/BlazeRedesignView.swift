import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ProxyWorkbenchCore

// MARK: - Root view
//
// Five stacked sections: hero (big toggle + status), mode, nodes,
// profile library, rules. Visual language follows the HTML mockup at
// design/blaze-simple.html — soft gradient hero, hairline-bordered
// grouped cells, mono destinations.

struct BlazeRedesignView: View {
    @EnvironmentObject var store: WorkbenchStore
    @State private var showImport = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                BlazeHeroCard()
                BlazeModeCard()
                BlazeNodeCard()
                BlazeProfilesCard(showImport: $showImport)
                BlazeRulesCard()
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .background(BlazeColors.windowBackground)
        .frame(minWidth: 720, minHeight: 640)
        .sheet(isPresented: $showImport) {
            BlazeImportSheet(isPresented: $showImport)
                .environmentObject(store)
        }
    }
}

// MARK: - Design tokens

enum BlazeColors {
    static let windowBackground = Color(nsColor: NSColor.windowBackgroundColor)
    static let cardBackground   = Color(nsColor: NSColor.controlBackgroundColor)
    static let cardInset        = Color(nsColor: NSColor.underPageBackgroundColor)
    static let pillBackground   = Color(nsColor: NSColor.quaternaryLabelColor).opacity(0.22)
    static let hairline         = Color(nsColor: NSColor.separatorColor)
    static let textPrimary      = Color(nsColor: NSColor.labelColor)
    static let textSecondary    = Color(nsColor: NSColor.secondaryLabelColor)
    static let textTertiary     = Color(nsColor: NSColor.tertiaryLabelColor)
    static let accent           = Color.accentColor
    static let positive         = Color(nsColor: .systemGreen)
    static let warning          = Color(nsColor: .systemOrange)
    static let danger           = Color(nsColor: .systemRed)
    static let purple           = Color(nsColor: .systemPurple)
}

private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(BlazeColors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(BlazeColors.hairline.opacity(0.55), lineWidth: 0.5)
            )
    }
}

private extension View {
    func blazeCard() -> some View { modifier(CardBackground()) }
}

private struct SectionHead: View {
    let title: String
    var action: (label: String, run: () -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.7)
                .foregroundStyle(BlazeColors.textTertiary)
            Spacer()
            if let action {
                Button {
                    action.run()
                } label: {
                    Text(action.label)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(BlazeColors.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
    }
}

// MARK: - 1. Hero (start/stop)

struct BlazeHeroCard: View {
    @EnvironmentObject var store: WorkbenchStore
    @State private var working = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(RadialGradient(
                    colors: [Color.white.opacity(isOn ? 0.5 : 0.15), .clear],
                    center: .topTrailing, startRadius: 0, endRadius: 220
                ))
                .frame(width: 260, height: 260)
                .offset(x: 60, y: -110)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)

            HStack(alignment: .center, spacing: 16) {
                heroToggle
                VStack(alignment: .leading, spacing: 3) {
                    Text(heroTitle)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(heroForeground)
                    Text(heroSubtitle)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(heroForeground.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(rightLabel.uppercased())
                        .font(.system(size: 10.5, weight: .semibold))
                        .kerning(0.4)
                        .foregroundStyle(heroForeground.opacity(0.7))
                    Text(rightValue)
                        .font(.system(size: 13.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(heroForeground)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
        }
        .background(heroGradient)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.black.opacity(0.07), lineWidth: 0.5)
        )
    }

    private var isOn: Bool { store.localProxyRunning || store.packetTunnelConnected }

    private var heroTitle: String {
        if working { return isOn ? "Stopping…" : "Starting…" }
        if isOn {
            let nodeName = store.globalProxyPolicy.isEmpty ? store.activeRoutingSummary : store.globalProxyPolicy
            return "Routing through \(nodeName)"
        }
        return "Blaze is off"
    }

    private var heroSubtitle: String {
        if isOn {
            return "leaf · HTTP \(store.proxyListenPort) · SOCKS5 \(store.socksListenPort)"
        }
        if store.profile.proxies.isEmpty {
            return "Add a profile below to begin"
        }
        return "Flip the switch to start the engine and packet tunnel"
    }

    private var rightLabel: String { isOn ? "↑↓ active" : "Profile" }
    private var rightValue: String {
        if isOn {
            return "\(store.proxyEvents.count) conns"
        }
        let nodes = store.profile.proxies.count
        let rules = store.profile.rules.count
        return nodes == 0 ? "—" : "\(nodes) nodes · \(rules) rules"
    }

    @ViewBuilder private var heroToggle: some View {
        Button {
            Task {
                working = true
                defer { working = false }
                if isOn {
                    await store.stopPacketTunnelAndRestoreSurge()
                } else {
                    await store.runStartupWorkflow()
                }
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(isOn ? BlazeColors.positive : Color(nsColor: NSColor.systemGray.withAlphaComponent(0.55)))
                    .frame(width: 56, height: 32)
                Circle()
                    .fill(Color.white)
                    .frame(width: 26, height: 26)
                    .padding(3)
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            }
            .animation(.easeInOut(duration: 0.18), value: isOn)
        }
        .buttonStyle(.plain)
        .disabled(working)
    }

    private var heroForeground: Color {
        isOn ? Color(red: 0.04, green: 0.31, blue: 0.70) : BlazeColors.textPrimary
    }

    private var heroGradient: LinearGradient {
        if isOn {
            return LinearGradient(
                colors: [Color(red: 0.90, green: 0.94, blue: 1.0), Color(red: 0.94, green: 0.97, blue: 1.0)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [Color(nsColor: NSColor.controlBackgroundColor), Color(nsColor: NSColor.controlBackgroundColor)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

// MARK: - 2. Mode card

struct BlazeModeCard: View {
    @EnvironmentObject var store: WorkbenchStore

    private var modes: [(ProxyRoutingMode, String, String)] {
        [
            (.direct, "Direct", "Skip all proxies"),
            (.ruleBased, "Rule-based", "Match → policy"),
            (.global, "Global", "Everything via one node"),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHead(title: "Mode")
            HStack(spacing: 4) {
                ForEach(modes, id: \.0) { mode, name, hint in
                    modeCell(mode: mode, name: name, hint: hint)
                }
            }
            .padding(4)
            .background(BlazeColors.pillBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder private func modeCell(mode: ProxyRoutingMode, name: String, hint: String) -> some View {
        let selected = store.proxyRoutingMode == mode
        Button {
            store.setProxyRoutingMode(mode)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(BlazeColors.textPrimary)
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(BlazeColors.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? BlazeColors.cardBackground : .clear)
                    .shadow(color: selected ? .black.opacity(0.06) : .clear, radius: 2, y: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 3. Node card

struct BlazeNodeCard: View {
    @EnvironmentObject var store: WorkbenchStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHead(
                title: nodeLabel,
                action: store.profile.proxies.isEmpty ? nil : ("Probe latency", { Task { await store.runLatencyChecks() } })
            )
            if store.profile.proxies.isEmpty {
                emptyState
            } else {
                nodeList
            }
        }
    }

    private var nodeLabel: String {
        switch store.proxyRoutingMode {
        case .direct: return "Node · ignored in direct mode"
        case .global: return "Node · everything goes here"
        case .ruleBased: return "Node · fallback for FINAL rule"
        }
    }

    @ViewBuilder private var emptyState: some View {
        Text("No proxy nodes — import a profile below.")
            .font(.system(size: 12))
            .foregroundStyle(BlazeColors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 18)
            .blazeCard()
    }

    @ViewBuilder private var nodeList: some View {
        let sorted = store.profile.proxies
            .sorted { lhs, rhs in
                let l = store.latencyResults[lhs.name]?.milliseconds ?? .max
                let r = store.latencyResults[rhs.name]?.milliseconds ?? .max
                return l == r ? lhs.name < rhs.name : l < r
            }
        VStack(spacing: 0) {
            ForEach(Array(sorted.enumerated()), id: \.element.id) { idx, proxy in
                if idx > 0 { Divider().padding(.leading, 14) }
                BlazeNodeRow(proxy: proxy)
            }
        }
        .blazeCard()
    }
}

private struct BlazeNodeRow: View {
    @EnvironmentObject var store: WorkbenchStore
    let proxy: ProxyNode

    var body: some View {
        let selected = proxy.name == store.globalProxyPolicy
        let ms = store.latencyResults[proxy.name]?.milliseconds
        let tone = latencyTone(ms)
        Button {
            store.setGlobalProxyPolicy(proxy.name)
        } label: {
            HStack(spacing: 14) {
                BlazeRadio(selected: selected)
                Text(displayFlag(for: proxy))
                    .font(.system(size: 17))
                    .frame(width: 20, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(proxy.name)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(BlazeColors.textPrimary)
                        .lineLimit(1)
                    Text(metaText(proxy))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(BlazeColors.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                latencyView(ms: ms, tone: tone)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func metaText(_ proxy: ProxyNode) -> String {
        if let port = proxy.port { return "\(proxy.kind.rawValue) · \(port)" }
        return proxy.kind.rawValue
    }

    @ViewBuilder private func latencyView(ms: Int?, tone: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(tone).frame(width: 6, height: 6)
            ZStack(alignment: .leading) {
                Capsule().fill(BlazeColors.pillBackground).frame(width: 56, height: 5)
                Capsule().fill(tone).frame(width: latencyFillWidth(ms), height: 5)
            }
            Text(ms.map { "\($0) ms" } ?? "—")
                .font(.system(size: 11.5, design: .monospaced).monospacedDigit())
                .foregroundStyle(ms == nil ? BlazeColors.textTertiary : BlazeColors.textSecondary)
                .frame(width: 56, alignment: .trailing)
        }
    }

    private func latencyFillWidth(_ ms: Int?) -> CGFloat {
        guard let ms else { return 0 }
        let clamped = max(0, min(56, CGFloat(56 - (ms - 50)) * 0.18 + 56))
        return max(6, min(56, clamped))
    }

    private func latencyTone(_ ms: Int?) -> Color {
        guard let ms else { return BlazeColors.textTertiary }
        if ms > 230 { return BlazeColors.danger }
        if ms > 140 { return BlazeColors.warning }
        return BlazeColors.positive
    }
}

private struct BlazeRadio: View {
    let selected: Bool
    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(selected ? BlazeColors.accent : BlazeColors.hairline.opacity(0.8), lineWidth: 1)
                .frame(width: 16, height: 16)
            if selected {
                Circle().fill(BlazeColors.accent).frame(width: 10, height: 10)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: selected)
    }
}

// MARK: - 4. Profiles card (config manager)

struct BlazeProfilesCard: View {
    @EnvironmentObject var store: WorkbenchStore
    @Binding var showImport: Bool
    @State private var renamingID: UUID?
    @State private var renameDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHead(
                title: "Profiles · \(store.savedProfiles.count) saved",
                action: ("+ Add profile", { showImport = true })
            )
            if store.savedProfiles.isEmpty {
                emptyState
            } else {
                listPanel
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No saved profiles yet")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(BlazeColors.textSecondary)
            Button("Import your first profile") { showImport = true }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(BlazeColors.accent)
        }
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .blazeCard()
    }

    @ViewBuilder private var listPanel: some View {
        let sorted = store.savedProfiles.sorted {
            if $0.id == store.activeProfileID { return true }
            if $1.id == store.activeProfileID { return false }
            return $0.lastUsedAt > $1.lastUsedAt
        }
        VStack(spacing: 0) {
            ForEach(Array(sorted.enumerated()), id: \.element.id) { idx, p in
                if idx > 0 { Divider().padding(.leading, 14) }
                profileRow(p)
            }
        }
        .blazeCard()
    }

    @ViewBuilder private func profileRow(_ p: SavedProfile) -> some View {
        let isActive = p.id == store.activeProfileID
        HStack(spacing: 14) {
            Button {
                store.activateSavedProfile(p.id)
            } label: {
                BlazeRadio(selected: isActive)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                if renamingID == p.id {
                    TextField(p.name, text: $renameDraft, onCommit: commitRename)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                } else {
                    Text(p.name)
                        .font(.system(size: 13, weight: isActive ? .semibold : .medium))
                        .foregroundStyle(BlazeColors.textPrimary)
                        .lineLimit(1)
                }
                Text(profileMeta(p))
                    .font(.system(size: 11))
                    .foregroundStyle(BlazeColors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isActive {
                Text("ACTIVE")
                    .font(.system(size: 9.5, weight: .bold))
                    .kerning(0.3)
                    .foregroundStyle(BlazeColors.positive)
                    .padding(.horizontal, 7).padding(.vertical, 2.5)
                    .background(BlazeColors.positive.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            HStack(spacing: 2) {
                if p.sourceURL != nil {
                    iconButton(systemName: "arrow.clockwise", help: "Refresh from URL") {
                        Task { await store.refreshSavedProfile(p.id) }
                    }
                }
                iconButton(systemName: "pencil", help: "Rename") {
                    renameDraft = p.name
                    renamingID = p.id
                }
                iconButton(systemName: "trash", help: "Delete", tint: BlazeColors.danger) {
                    store.deleteSavedProfile(p.id)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func commitRename() {
        if let id = renamingID {
            store.renameSavedProfile(id, to: renameDraft)
        }
        renamingID = nil
        renameDraft = ""
    }

    private func profileMeta(_ p: SavedProfile) -> String {
        let url = p.sourceURL ?? "local"
        let updated = relativeDate(p.lastUsedAt)
        return "\(url)  ·  used \(updated)"
    }

    private func relativeDate(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    @ViewBuilder private func iconButton(systemName: String, help: String, tint: Color = BlazeColors.textTertiary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - 5. Rules card

struct BlazeRulesCard: View {
    @EnvironmentObject var store: WorkbenchStore
    @State private var query: String = ""
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHead(
                title: "Rules · \(store.profile.rules.count) loaded",
                action: store.profile.rules.isEmpty ? nil : ("Refresh sources", { Task { await store.importRuleSets() } })
            )
            if store.profile.rules.isEmpty {
                emptyState
            } else {
                searchField
                listPanel
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        Text("No rules — activate a profile to populate this list.")
            .font(.system(size: 12))
            .foregroundStyle(BlazeColors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 22)
            .blazeCard()
    }

    private var filteredRules: [ProxyRule] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return store.profile.rules }
        return store.profile.rules.filter {
            $0.value.lowercased().contains(q) ||
            $0.policy.lowercased().contains(q) ||
            $0.type.lowercased().contains(q)
        }
    }

    @ViewBuilder private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(BlazeColors.textTertiary)
            TextField("Filter by value, policy, or kind…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(BlazeColors.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(BlazeColors.cardInset)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(BlazeColors.hairline.opacity(0.55), lineWidth: 0.5)
        )
    }

    @ViewBuilder private var listPanel: some View {
        let visible = expanded ? filteredRules : Array(filteredRules.prefix(60))
        VStack(spacing: 0) {
            if visible.isEmpty {
                Text("No rules match “\(query)”")
                    .font(.system(size: 12))
                    .foregroundStyle(BlazeColors.textSecondary)
                    .padding(.vertical, 20)
            } else {
                ForEach(Array(visible.enumerated()), id: \.element.id) { idx, rule in
                    if idx > 0 { Divider().padding(.leading, 16) }
                    ruleRow(rule)
                }
                if filteredRules.count > 60 && !expanded {
                    Button {
                        expanded = true
                    } label: {
                        Text("Show all \(filteredRules.count)")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(BlazeColors.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(BlazeColors.accent.opacity(0.05))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .blazeCard()
    }

    @ViewBuilder private func ruleRow(_ rule: ProxyRule) -> some View {
        HStack(spacing: 12) {
            kindBadge(rule.type)
                .frame(width: 100, alignment: .leading)
            Text(rule.value.isEmpty ? "—" : rule.value)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(BlazeColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            policyChip(rule.policy)
                .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7.5)
    }

    @ViewBuilder private func kindBadge(_ type: String) -> some View {
        let color = kindColor(type)
        Text(shortKind(type))
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .kerning(0.3)
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func kindColor(_ type: String) -> Color {
        if type.hasPrefix("DOMAIN") { return BlazeColors.accent }
        if type.hasPrefix("IP-CIDR") { return BlazeColors.positive }
        if type == "GEOIP" { return BlazeColors.warning }
        if type == "DEST-PORT" || type == "SRC-PORT" || type == "IN-PORT" { return BlazeColors.purple }
        if type == "URL-REGEX" { return BlazeColors.danger }
        if type == "FINAL" || type == "MATCH" { return BlazeColors.textSecondary }
        return BlazeColors.textSecondary
    }

    private func shortKind(_ type: String) -> String {
        switch type {
        case "DOMAIN-SUFFIX": "DOMAIN-SFX"
        case "DOMAIN-KEYWORD": "DOMAIN-KW"
        default: type
        }
    }

    @ViewBuilder private func policyChip(_ policy: String) -> some View {
        let tone: Color = policy == "DIRECT" ? BlazeColors.textSecondary :
            (policy.contains("REJECT") ? BlazeColors.danger : BlazeColors.accent)
        Text(shortPolicy(policy))
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tone)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tone.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .lineLimit(1)
    }

    private func shortPolicy(_ s: String) -> String {
        s.count > 22 ? String(s.prefix(22)) + "…" : s
    }
}

// MARK: - Import sheet

struct BlazeImportSheet: View {
    @EnvironmentObject var store: WorkbenchStore
    @Binding var isPresented: Bool

    enum SourceTab: Hashable { case url, file, paste }
    @State private var tab: SourceTab = .url
    @State private var urlText: String = ""
    @State private var nameText: String = ""
    @State private var pasteText: String = ""
    @State private var alsoImportRuleSets = true
    @State private var activateAfterImport = true
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add profile")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(BlazeColors.textPrimary)
                Text("Import a Surge-style config from a URL, a local file, or paste it directly.")
                    .font(.system(size: 12))
                    .foregroundStyle(BlazeColors.textSecondary)
            }
            .padding(.bottom, 16)

            HStack(spacing: 4) {
                tabButton("From URL", value: .url)
                tabButton("From file", value: .file)
                tabButton("Paste",     value: .paste)
            }
            .padding(4)
            .background(BlazeColors.pillBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 14)

            switch tab {
            case .url:   urlTab
            case .file:  fileTab
            case .paste: pasteTab
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $alsoImportRuleSets) {
                    Text("Also import rule sets referenced by this profile")
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                Toggle(isOn: $activateAfterImport) {
                    Text("Activate immediately after import")
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
            }
            .padding(.top, 14)

            Spacer(minLength: 16)

            HStack {
                if isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(action: doImport) {
                    Text(isBusy ? "Importing…" : "Import")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    @ViewBuilder private func tabButton(_ label: String, value: SourceTab) -> some View {
        let selected = tab == value
        Button { tab = value } label: {
            Text(label)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? BlazeColors.textPrimary : BlazeColors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? BlazeColors.cardBackground : .clear)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var urlTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("Subscription URL")
            inputField($urlText, placeholder: "https://example.com/sub")
            fieldLabel("Name (optional)")
            inputField($nameText, placeholder: "e.g. tikiki")
        }
    }

    @ViewBuilder private var fileTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a .conf / .ini / .yaml profile file from disk.")
                .font(.system(size: 12))
                .foregroundStyle(BlazeColors.textSecondary)
            Button {
                pickFile()
            } label: {
                HStack {
                    Image(systemName: "folder")
                    Text("Choose file…")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(BlazeColors.cardInset)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(BlazeColors.textPrimary)
            }
            .buttonStyle(.plain)
            fieldLabel("Name (optional)")
            inputField($nameText, placeholder: "Falls back to file name")
        }
    }

    @ViewBuilder private var pasteTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("Name")
            inputField($nameText, placeholder: "Required")
            fieldLabel("Profile contents")
            TextEditor(text: $pasteText)
                .font(.system(size: 11.5, design: .monospaced))
                .frame(height: 140)
                .padding(8)
                .background(BlazeColors.cardInset)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(BlazeColors.hairline.opacity(0.5), lineWidth: 0.5))
        }
    }

    @ViewBuilder private func fieldLabel(_ s: String) -> some View {
        Text(s).font(.system(size: 11, weight: .medium)).foregroundStyle(BlazeColors.textSecondary)
    }

    @ViewBuilder private func inputField(_ binding: Binding<String>, placeholder: String) -> some View {
        TextField(placeholder, text: binding)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(BlazeColors.cardInset)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(BlazeColors.hairline.opacity(0.5), lineWidth: 0.5))
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a profile file"
        panel.allowedContentTypes = [.text, .plainText, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            isBusy = true
            store.importProfileFromFile(url, named: nameText)
            isBusy = false
            isPresented = false
        }
    }

    private func doImport() {
        switch tab {
        case .url:
            isBusy = true
            let url = urlText
            let name = nameText
            let alsoRules = alsoImportRuleSets
            Task {
                await store.importProfileFromURL(url, named: name, importRuleSets: alsoRules)
                await MainActor.run {
                    isBusy = false
                    isPresented = false
                }
            }
        case .file:
            pickFile()
        case .paste:
            isBusy = true
            store.importProfileFromText(pasteText, named: nameText)
            isBusy = false
            isPresented = false
        }
    }
}

// MARK: - Helpers

private func displayFlag(for proxy: ProxyNode) -> String {
    let lower = proxy.name.lowercased()
    if lower.contains("hong kong") || lower.contains("🇭🇰") || lower.contains("hk") { return "🇭🇰" }
    if lower.contains("singapore") || lower.contains("🇸🇬") || lower.contains("sg") { return "🇸🇬" }
    if lower.contains("tokyo") || lower.contains("japan") || lower.contains("🇯🇵") || lower.contains("jp") { return "🇯🇵" }
    if lower.contains("seoul") || lower.contains("korea") || lower.contains("🇰🇷") || lower.contains("kr") { return "🇰🇷" }
    if lower.contains("london") || lower.contains("🇬🇧") || lower.contains("uk") { return "🇬🇧" }
    if lower.contains("frankfurt") || lower.contains("germany") || lower.contains("🇩🇪") { return "🇩🇪" }
    if lower.contains("los angeles") || lower.contains(" us") || lower.contains("🇺🇸") { return "🇺🇸" }
    if proxy.kind == .direct { return "⚡" }
    if proxy.kind == .reject { return "🚫" }
    return "🌐"
}
