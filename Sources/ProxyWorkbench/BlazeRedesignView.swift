import AppKit
import SwiftUI
import ProxyWorkbenchCore

// MARK: - Root view
//
// Minimal Blaze UI. Four concerns, single window, no sidebar.
//   1. Big start/stop toggle that drives the full startup pipeline
//      (stop Surge → activate sysext → start leaf → install + start
//      packet tunnel → optional probes). Clicking it is the SAME
//      code path as the diagnostics workflow that the user already
//      saw working — so traffic actually routes through leaf the
//      moment the toggle flips on.
//   2. Routing mode (Direct / Rule-based / Global).
//   3. Node selector — the active proxy that traffic falls back to.
//   4. Rules — searchable list of the profile's rules.

struct BlazeRedesignView: View {
    @EnvironmentObject var store: WorkbenchStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                BlazeStatusCard()
                BlazeModeCard()
                BlazeNodeCard()
                BlazeRulesCard()
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 720, minHeight: 640)
    }
}

// MARK: - Shared visuals

private enum BlazeTokens {
    static let panelRadius: CGFloat = 10
    static let buttonRadius: CGFloat = 6
}

private extension Color {
    static var blazeAccent: Color { .accentColor }
    static var blazePositive: Color { Color(nsColor: .systemGreen) }
    static var blazeWarning: Color { Color(nsColor: .systemOrange) }
    static var blazeDanger: Color { Color(nsColor: .systemRed) }
    static var blazeBorder: Color { Color(nsColor: .separatorColor) }
    static var blazeCard: Color { Color(nsColor: .controlBackgroundColor) }
    static var blazeTile: Color { Color(nsColor: .controlBackgroundColor) }
}

private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.blazeCard)
            .clipShape(RoundedRectangle(cornerRadius: BlazeTokens.panelRadius))
            .overlay(
                RoundedRectangle(cornerRadius: BlazeTokens.panelRadius)
                    .strokeBorder(Color.blazeBorder.opacity(0.55), lineWidth: 0.5)
            )
    }
}

private extension View {
    func blazeCard() -> some View { modifier(CardBackground()) }
}

private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(1.0)
            .foregroundStyle(.tertiary)
            .padding(.leading, 4)
    }
}

// MARK: - 1. Start / Stop card

struct BlazeStatusCard: View {
    @EnvironmentObject var store: WorkbenchStore
    @State private var working = false

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            Toggle(isOn: Binding(
                get: { isOn },
                set: { newValue in
                    Task {
                        working = true
                        defer { working = false }
                        if newValue {
                            // Same code path as the diagnostics workflow —
                            // ensures packet tunnel is actually up, not just
                            // local listeners. Probes at the end double as a
                            // sanity check that Google/etc. respond through
                            // the tunnel.
                            await store.runStartupWorkflow()
                        } else {
                            await store.stopPacketTunnelAndRestoreSurge()
                        }
                    }
                }
            )) { EmptyView() }
            .toggleStyle(.switch)
            .controlSize(.large)
            .labelsHidden()
            .disabled(working)

            VStack(alignment: .leading, spacing: 4) {
                Text(headlineText)
                    .font(.system(size: 18, weight: .semibold))
                Text(subtitleText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if working {
                ProgressView().controlSize(.small)
            } else {
                statusBadge
            }
        }
        .padding(20)
        .blazeCard()
    }

    private var isOn: Bool {
        store.localProxyRunning || store.packetTunnelConnected
    }

    private var headlineText: String {
        if isOn { return "Blaze is routing your traffic" }
        return "Blaze is off"
    }

    private var subtitleText: String {
        if isOn {
            return "\(store.activeRoutingSummary)  ·  HTTP \(store.proxyListenPort) / SOCKS5 \(store.socksListenPort)"
        }
        if store.profile.proxies.isEmpty && store.profile.rules.isEmpty {
            return "Import a profile to begin (Settings ▸ Load Sample for a demo)"
        }
        return "Flip the switch to start the leaf engine and packet tunnel"
    }

    @ViewBuilder private var statusBadge: some View {
        let label = isOn ? "Connected" : "Off"
        let tone: Color = isOn ? .blazePositive : .secondary
        HStack(spacing: 6) {
            Circle().fill(tone).frame(width: 8, height: 8)
            Text(label).font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(tone.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: BlazeTokens.buttonRadius))
    }
}

// MARK: - 2. Mode card

struct BlazeModeCard: View {
    @EnvironmentObject var store: WorkbenchStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Mode")
            HStack(spacing: 1) {
                ForEach(modes, id: \.0) { (mode, label, hint) in
                    modeButton(mode: mode, label: label, hint: hint)
                }
            }
            .padding(3)
            .background(Color.blazeTile)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.blazeBorder.opacity(0.5), lineWidth: 0.5))
        }
    }

    private var modes: [(ProxyRoutingMode, String, String)] {
        [
            (.direct, "Direct", "Skip all proxies"),
            (.ruleBased, "Rule-based", "Match destination → rule → policy"),
            (.global, "Global", "Route everything through the selected node"),
        ]
    }

    @ViewBuilder private func modeButton(mode: ProxyRoutingMode, label: String, hint: String) -> some View {
        let selected = store.proxyRoutingMode == mode
        Button {
            store.setProxyRoutingMode(mode)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color(nsColor: .windowBackgroundColor) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? Color.blazeAccent.opacity(0.45) : .clear, lineWidth: 1)
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
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: nodeLabel)
                Spacer()
                Button {
                    Task { await store.runLatencyChecks() }
                } label: {
                    Text("Probe latency")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.blazeAccent)
                }
                .buttonStyle(.plain)
                .disabled(store.profile.proxies.isEmpty)
            }

            if store.profile.proxies.isEmpty {
                emptyState
            } else {
                if store.proxyRoutingMode == .ruleBased {
                    ruleBasedHint
                }
                nodeList
            }
        }
    }

    private var nodeLabel: String {
        switch store.proxyRoutingMode {
        case .direct: return "Node · ignored in direct mode"
        case .global: return "Node · everything goes here"
        case .ruleBased: return "Node · fallback when no rule matches"
        }
    }

    @ViewBuilder private var emptyState: some View {
        Text("No proxy nodes — paste a profile URL in Settings.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .center)
            .blazeCard()
    }

    @ViewBuilder private var ruleBasedHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
            Text("In Rule-based mode this node only catches the FINAL rule.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.blazeTile)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.blazeBorder.opacity(0.5), lineWidth: 0.5))
    }

    @ViewBuilder private var nodeList: some View {
        let sorted = store.profile.proxies
            .sorted { lhs, rhs in
                let l = store.latencyResults[lhs.name]?.milliseconds ?? .max
                let r = store.latencyResults[rhs.name]?.milliseconds ?? .max
                return l == r ? lhs.name < rhs.name : l < r
            }
        VStack(spacing: 0) {
            ForEach(sorted) { proxy in
                nodeRow(proxy)
            }
        }
        .blazeCard()
    }

    @ViewBuilder private func nodeRow(_ proxy: ProxyNode) -> some View {
        let selected = proxy.name == store.globalProxyPolicy
        let ms = store.latencyResults[proxy.name]?.milliseconds
        let tone: Color = ms.map { $0 > 180 ? .blazeDanger : ($0 > 130 ? .blazeWarning : .blazePositive) } ?? .secondary

        Button {
            store.setGlobalProxyPolicy(proxy.name)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Color.blazeAccent : .secondary)
                Text(displayFlag(for: proxy)).font(.system(size: 14))
                VStack(alignment: .leading, spacing: 1) {
                    Text(proxy.name).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                    Text("\(proxy.kind.rawValue)\(proxy.port.map { " · " + String($0) } ?? "")")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(tone).frame(width: 6, height: 6)
                    Text(ms.map { "\($0) ms" } ?? "—")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(ms == nil ? .tertiary : .primary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(selected ? Color.blazeAccent.opacity(0.06) : .clear)
            .contentShape(Rectangle())
            .overlay(Divider().background(Color.blazeBorder.opacity(0.3)), alignment: .bottom)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 4. Rules card

struct BlazeRulesCard: View {
    @EnvironmentObject var store: WorkbenchStore
    @State private var query: String = ""
    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "Rules · \(store.profile.rules.count) loaded")
                Spacer()
                Button {
                    Task { await store.importRuleSets() }
                } label: {
                    Text(store.remoteImportInProgress ? "Refreshing…" : "Refresh sources")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.blazeAccent)
                }
                .buttonStyle(.plain)
                .disabled(store.remoteImportInProgress)
            }

            searchField

            if filteredRules.isEmpty {
                emptyState
            } else {
                listPanel
            }
        }
    }

    private var filteredRules: [ProxyRule] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return store.profile.rules }
        return store.profile.rules.filter {
            $0.value.lowercased().contains(trimmed) ||
            $0.policy.lowercased().contains(trimmed) ||
            $0.type.lowercased().contains(trimmed)
        }
    }

    @ViewBuilder private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Filter by value, policy, or kind…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.blazeTile)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.blazeBorder.opacity(0.5), lineWidth: 0.5))
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 4) {
            Text(query.isEmpty ? "No rules in this profile." : "No rules match “\(query)”.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if !query.isEmpty {
                Button("Clear filter") { query = "" }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.blazeAccent)
                    .font(.system(size: 11))
            }
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .blazeCard()
    }

    private var visibleRules: [ProxyRule] {
        expanded ? filteredRules : Array(filteredRules.prefix(50))
    }

    @ViewBuilder private var listPanel: some View {
        VStack(spacing: 0) {
            ForEach(visibleRules) { rule in
                ruleRow(rule)
            }
            if filteredRules.count > 50 && !expanded {
                Button {
                    expanded = true
                } label: {
                    Text("Show all \(filteredRules.count)")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.blazeAccent)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(Color.blazeAccent.opacity(0.05))
                }
                .buttonStyle(.plain)
            }
        }
        .blazeCard()
    }

    @ViewBuilder private func ruleRow(_ rule: ProxyRule) -> some View {
        HStack(spacing: 12) {
            kindBadge(rule.type)
            Text(rule.value.isEmpty ? "·" : rule.value)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            policyChip(rule.policy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .overlay(Divider().background(Color.blazeBorder.opacity(0.3)), alignment: .bottom)
    }

    @ViewBuilder private func kindBadge(_ type: String) -> some View {
        let color: Color = kindColor(type)
        Text(shortKind(type))
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .kerning(0.3)
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .frame(width: 100, alignment: .leading)
    }

    private func kindColor(_ type: String) -> Color {
        if type.hasPrefix("DOMAIN") { return .blazeAccent }
        if type.hasPrefix("IP-CIDR") { return .blazePositive }
        if type == "GEOIP" { return .blazeWarning }
        if type == "DEST-PORT" { return Color(nsColor: .systemPurple) }
        if type == "URL-REGEX" { return .blazeDanger }
        if type == "FINAL" || type == "MATCH" { return .secondary }
        return .secondary
    }

    private func shortKind(_ type: String) -> String {
        switch type {
        case "DOMAIN-SUFFIX": "DOMAIN-SFX"
        case "DOMAIN-KEYWORD": "DOMAIN-KW"
        default: type
        }
    }

    @ViewBuilder private func policyChip(_ policy: String) -> some View {
        let tone: Color = policy == "DIRECT" ? .secondary : (policy.contains("REJECT") ? .blazeDanger : .blazeAccent)
        Text(shortPolicy(policy))
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tone)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tone.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .frame(width: 140, alignment: .trailing)
    }

    private func shortPolicy(_ s: String) -> String {
        s.count > 24 ? String(s.prefix(24)) + "…" : s
    }
}

// MARK: - Helpers

private func displayFlag(for proxy: ProxyNode) -> String {
    let lower = proxy.name.lowercased()
    if lower.contains("hong kong") || lower.contains("🇭🇰") || lower.contains("hk") { return "🇭🇰" }
    if lower.contains("singapore") || lower.contains("🇸🇬") || lower.contains("sg") { return "🇸🇬" }
    if lower.contains("tokyo") || lower.contains("japan") || lower.contains("🇯🇵") { return "🇯🇵" }
    if lower.contains("seoul") || lower.contains("korea") || lower.contains("🇰🇷") { return "🇰🇷" }
    if lower.contains("london") || lower.contains("🇬🇧") || lower.contains("uk") { return "🇬🇧" }
    if lower.contains("frankfurt") || lower.contains("germany") || lower.contains("🇩🇪") { return "🇩🇪" }
    if lower.contains("los angeles") || lower.contains("us ") || lower.contains("🇺🇸") { return "🇺🇸" }
    if proxy.kind == .direct { return "⚡" }
    if proxy.kind == .reject { return "🚫" }
    return "🌐"
}
