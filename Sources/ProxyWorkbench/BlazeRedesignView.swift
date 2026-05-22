import AppKit
import SwiftUI
import ProxyWorkbenchCore

// MARK: - Page enum

enum BlazePage: String, CaseIterable, Identifiable {
    case overview, traffic, policies, rules, diagnostics, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .traffic: "Traffic"
        case .policies: "Policies"
        case .rules: "Rules"
        case .diagnostics: "Diagnostics"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .traffic: "list.bullet.indent"
        case .policies: "globe"
        case .rules: "list.dash"
        case .diagnostics: "shield.lefthalf.filled"
        case .settings: "gearshape"
        }
    }
}

// MARK: - Design tokens

enum BlazeUI {
    static let windowRadius: CGFloat = 10
    static let panelRadius: CGFloat = 10
    static let cardRadius: CGFloat = 8
    static let buttonRadius: CGFloat = 6
    static let chipRadius: CGFloat = 4
    static let sidebarWidth: CGFloat = 220
    static let topBarHeight: CGFloat = 52
    static let statusBarHeight: CGFloat = 28
    static let bodyFont: Font = .system(size: 13)
    static let subtitleFont: Font = .system(size: 11)
    static let captionFont: Font = .system(size: 10).weight(.semibold)
    static let monoSmall: Font = .system(size: 11, design: .monospaced)
    static let monoTiny: Font = .system(size: 10.5, design: .monospaced)
}

// MARK: - Tonal colors

private extension Color {
    static var blazeAccent: Color { Color.accentColor }
    static var blazePositive: Color { Color(nsColor: NSColor.systemGreen) }
    static var blazeWarning: Color { Color(nsColor: NSColor.systemOrange) }
    static var blazeDanger: Color { Color(nsColor: NSColor.systemRed) }
    static var blazePurple: Color { Color(nsColor: NSColor.systemPurple) }

    static var blazeTextPrimary: Color { Color(nsColor: NSColor.labelColor) }
    static var blazeTextSecondary: Color { Color(nsColor: NSColor.secondaryLabelColor) }
    static var blazeTextTertiary: Color { Color(nsColor: NSColor.tertiaryLabelColor) }
    static var blazeBorder: Color { Color(nsColor: NSColor.separatorColor) }
    static var blazeTile: Color { Color(nsColor: NSColor.controlBackgroundColor) }
    static var blazeTileStrong: Color { Color(nsColor: NSColor.windowBackgroundColor).opacity(0.6) }
    static var blazeCard: Color { Color(nsColor: NSColor.controlBackgroundColor) }
}

// MARK: - Reusable components

struct BlazeCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blazeCard)
            .clipShape(RoundedRectangle(cornerRadius: BlazeUI.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: BlazeUI.cardRadius)
                    .strokeBorder(Color.blazeBorder.opacity(0.55), lineWidth: 0.5)
            )
    }
}

struct BlazePanel<Content: View>: View {
    var title: String
    var accessory: AnyView?
    @ViewBuilder var content: () -> Content

    init(title: String, accessory: AnyView? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                accessory
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            content()
        }
        .background(Color.blazeCard)
        .clipShape(RoundedRectangle(cornerRadius: BlazeUI.panelRadius))
        .overlay(
            RoundedRectangle(cornerRadius: BlazeUI.panelRadius)
                .strokeBorder(Color.blazeBorder.opacity(0.55), lineWidth: 0.5)
        )
    }
}

enum ChipTone { case neutral, accent, positive, warning, danger, purple }

struct Chip: View {
    let text: String
    var tone: ChipTone = .neutral
    var monospaced: Bool = false

    private var fg: Color {
        switch tone {
        case .neutral: .blazeTextSecondary
        case .accent: .blazeAccent
        case .positive: .blazePositive
        case .warning: .blazeWarning
        case .danger: .blazeDanger
        case .purple: .blazePurple
        }
    }
    private var bg: Color {
        switch tone {
        case .neutral: Color.blazeTextSecondary.opacity(0.10)
        case .accent: Color.blazeAccent.opacity(0.13)
        case .positive: Color.blazePositive.opacity(0.16)
        case .warning: Color.blazeWarning.opacity(0.18)
        case .danger: Color.blazeDanger.opacity(0.15)
        case .purple: Color.blazePurple.opacity(0.15)
        }
    }

    var body: some View {
        Text(text)
            .font(monospaced ? .system(size: 10, design: .monospaced).weight(.semibold) : .system(size: 10, weight: .semibold))
            .kerning(0.4)
            .foregroundStyle(fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: BlazeUI.chipRadius))
            .overlay(
                RoundedRectangle(cornerRadius: BlazeUI.chipRadius)
                    .strokeBorder(fg.opacity(0.18), lineWidth: 0.5)
            )
    }
}

struct StatusDot: View {
    var tone: ChipTone = .positive
    var pulse: Bool = false

    private var fill: Color {
        switch tone {
        case .neutral: .blazeTextTertiary
        case .accent: .blazeAccent
        case .positive: .blazePositive
        case .warning: .blazeWarning
        case .danger: .blazeDanger
        case .purple: .blazePurple
        }
    }

    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: 8, height: 8)
            .overlay(
                Circle().fill(fill.opacity(0.25)).scaleEffect(pulse ? pulseScale : 1.6)
            )
            .compositingGroup()
            .onAppear {
                if pulse {
                    withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                        pulseScale = 2.4
                    }
                }
            }
    }
}

struct KBDPill: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(.secondary)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.blazeBorder.opacity(0.55), lineWidth: 0.5)
            )
    }
}

struct LabeledStat: View {
    let label: String
    let value: String
    var caption: String? = nil
    var tone: ChipTone = .neutral

    private var valueColor: Color {
        switch tone {
        case .danger: .blazeDanger
        case .warning: .blazeWarning
        case .positive: .blazePositive
        case .accent: .blazeAccent
        default: .blazeTextPrimary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(BlazeUI.captionFont).kerning(0.8).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(valueColor)
            if let caption {
                Text(caption).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Sidebar

struct BlazeSidebar: View {
    @Binding var page: BlazePage
    @EnvironmentObject var store: WorkbenchStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            brand
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Divider()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    group(label: "Tools", items: [.overview, .traffic])
                    group(label: "Routing", items: [.policies, .rules])
                    group(label: "System", items: [.diagnostics, .settings])
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 6)
            }
            Spacer(minLength: 0)
            Divider()
            footer.padding(10)
        }
        .frame(width: BlazeUI.sidebarWidth, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.blazeBorder.opacity(0.6)).frame(width: 0.5)
        }
    }

    @ViewBuilder private var brand: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(colors: [Color(red: 1.0, green: 0.43, blue: 0.28),
                                                Color(red: 1.0, green: 0.24, blue: 0.45)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 22, height: 22)
                Image(systemName: "flame.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.95))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Blaze").font(.system(size: 13, weight: .semibold))
                Text("0.1.0 · build 62")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    @ViewBuilder private func group(label: String, items: [BlazePage]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(1.1)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            ForEach(items) { item in
                sidebarRow(item)
            }
        }
    }

    @ViewBuilder private func sidebarRow(_ item: BlazePage) -> some View {
        let isSelected = page == item
        Button {
            page = item
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(isSelected ? Color.blazeAccent : .secondary)
                Text(item.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(.primary)
                Spacer()
                if let count = count(for: item) {
                    Text(count)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.primary.opacity(0.06) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text("HC").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text("Huazhao Chen").font(.system(size: 12, weight: .medium))
                Text("Developer ID · HYF3XBWBL2")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private func count(for item: BlazePage) -> String? {
        switch item {
        case .traffic: return "\(store.proxyEvents.count)"
        case .policies: return "\(store.profile.proxies.count)"
        case .rules: return formatCount(store.profile.rules.count)
        default: return nil
        }
    }
}

// MARK: - Top bar

struct BlazeTopBar: View {
    let page: BlazePage
    var subtitle: String?
    @EnvironmentObject var store: WorkbenchStore

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(page.title).font(.system(size: 13, weight: .semibold))
                Text(subtitle ?? defaultSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.leading, 4)
            Spacer()
            cmdK
            statusChip
            primaryAction
        }
        .padding(.horizontal, 16)
        .frame(height: BlazeUI.topBarHeight)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.blazeBorder.opacity(0.55)).frame(height: 0.5)
        }
    }

    private var defaultSubtitle: String {
        if store.localProxyRunning {
            return "All systems operational · \(store.activeRoutingSummary)"
        }
        if store.profile.proxies.isEmpty && store.profile.rules.isEmpty {
            return "Import a profile to begin"
        }
        return store.activeRoutingSummary
    }

    @ViewBuilder private var cmdK: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text("Search anything…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 24)
            KBDPill(label: "⌘ K")
        }
        .padding(.horizontal, 10)
        .frame(width: 260, height: 28)
        .background(Color.blazeTile)
        .clipShape(RoundedRectangle(cornerRadius: BlazeUI.buttonRadius))
        .overlay(
            RoundedRectangle(cornerRadius: BlazeUI.buttonRadius)
                .strokeBorder(Color.blazeBorder.opacity(0.55), lineWidth: 0.5)
        )
    }

    @ViewBuilder private var statusChip: some View {
        let running = store.localProxyRunning
        HStack(spacing: 7) {
            StatusDot(tone: running ? .positive : .neutral)
            Text(running ? "leaf" : "stopped")
            if running {
                Text("·").foregroundStyle(.tertiary)
                Text(store.globalProxyPolicy.isEmpty ? "—" : store.globalProxyPolicy).lineLimit(1)
                Text("·").foregroundStyle(.tertiary)
                Text("\(store.proxyPolicyStats.reduce(0) { $0 + $1.count }) hits").lineLimit(1)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background((running ? Color.blazePositive : Color.gray).opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: BlazeUI.buttonRadius))
        .overlay(
            RoundedRectangle(cornerRadius: BlazeUI.buttonRadius)
                .strokeBorder(Color.blazeBorder.opacity(0.55), lineWidth: 0.5)
        )
    }

    @ViewBuilder private var primaryAction: some View {
        let running = store.localProxyRunning
        Button {
            Task {
                if running {
                    await store.disableSystemProxyAndStop()
                } else {
                    await store.startAndApplySystemProxy()
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: running ? "stop.fill" : "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(running ? "Stop Proxy" : "Start Proxy")
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .frame(height: 28)
            .foregroundStyle(running ? Color.blazeDanger : .white)
            .background(running ? Color.blazeDanger.opacity(0.14) : Color.blazeAccent)
            .clipShape(RoundedRectangle(cornerRadius: BlazeUI.buttonRadius))
            .overlay(
                RoundedRectangle(cornerRadius: BlazeUI.buttonRadius)
                    .strokeBorder(Color.blazeBorder.opacity(0.4), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Status strip

struct BlazeStatusStrip: View {
    @EnvironmentObject var store: WorkbenchStore

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                StatusDot(tone: store.localProxyRunning ? .positive : .neutral)
                Text(store.localProxyRunning ? "leaf · \(store.globalProxyPolicy.isEmpty ? "—" : store.globalProxyPolicy)" : "leaf · idle")
                Text("·").foregroundStyle(.tertiary)
                Text(store.packetTunnelStatusText).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 18) {
                Label("12.4 KB/s", systemImage: "arrow.up")
                    .labelStyle(StripLabelStyle())
                Label("47.1 KB/s", systemImage: "arrow.down")
                    .labelStyle(StripLabelStyle())
            }

            HStack(spacing: 10) {
                Text("\(store.proxyPolicyStats.reduce(0) { $0 + $1.count }) hits")
                Text("·").foregroundStyle(.tertiary)
                Text("en1")
                KBDPill(label: "⌘ K")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: BlazeUI.statusBarHeight)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.blazeBorder.opacity(0.55)).frame(height: 0.5)
        }
    }
}

private struct StripLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            configuration.title
        }
    }
}

// MARK: - Root view

struct BlazeRedesignView: View {
    @EnvironmentObject var store: WorkbenchStore
    @State private var page: BlazePage = .overview

    var body: some View {
        HStack(spacing: 0) {
            BlazeSidebar(page: $page)
            VStack(spacing: 0) {
                BlazeTopBar(page: page)
                pageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                BlazeStatusStrip()
            }
        }
        .frame(minWidth: 1100, minHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var pageContent: some View {
        ScrollView {
            switch page {
            case .overview: OverviewPage()
            case .traffic: TrafficPage()
            case .policies: PoliciesPage()
            case .rules: RulesPage()
            case .diagnostics: DiagnosticsPage()
            case .settings: SettingsPage()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Overview page

struct OverviewPage: View {
    @EnvironmentObject var store: WorkbenchStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            hero
            statRow
            twoCol
            selfTest
        }
        .padding(20)
    }

    @ViewBuilder private var hero: some View {
        HStack(spacing: 0) {
            HStack(spacing: 18) {
                Toggle(isOn: Binding(
                    get: { store.localProxyRunning },
                    set: { newValue in
                        Task {
                            if newValue {
                                await store.startAndApplySystemProxy()
                            } else {
                                await store.disableSystemProxyAndStop()
                            }
                        }
                    }
                )) {
                    EmptyView()
                }
                .toggleStyle(.switch)
                .controlSize(.large)
                .labelsHidden()
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.localProxyRunning ? "Blaze is routing your traffic" : "Blaze is idle")
                        .font(.system(size: 19, weight: .semibold))
                    Text(heroSubtitle)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Divider().frame(height: 88)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Throughput · last 5 min")
                        .font(.system(size: 10, weight: .semibold))
                        .kerning(0.6)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("peak 124 KB/s")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                BlazeSparkline()
                    .frame(height: 50)
                HStack(spacing: 16) {
                    Label("12.4 KB/s", systemImage: "arrow.up")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .labelStyle(IconLeadingStyle())
                    Label("47.1 KB/s", systemImage: "arrow.down")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .labelStyle(IconLeadingStyle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(width: 340, alignment: .leading)
        }
        .background(
            ZStack {
                Color.blazeCard
                LinearGradient(colors: [Color.blazeAccent.opacity(0.06), .clear], startPoint: .leading, endPoint: .center)
                LinearGradient(colors: [.clear, Color.blazePositive.opacity(0.06)], startPoint: .center, endPoint: .trailing)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: BlazeUI.panelRadius))
        .overlay(
            RoundedRectangle(cornerRadius: BlazeUI.panelRadius)
                .strokeBorder(Color.blazeBorder.opacity(0.55), lineWidth: 0.5)
        )
        .frame(minHeight: 120)
    }

    private var heroSubtitle: String {
        if store.localProxyRunning {
            return "Engine leaf · pid \(ProcessInfo.processInfo.processIdentifier) · HTTP \(store.proxyListenPort) / SOCKS5 \(store.socksListenPort) · boundif en1"
        }
        return "Engine leaf · stopped · ports \(store.proxyListenPort) / \(store.socksListenPort) reserved"
    }

    @ViewBuilder private var statRow: some View {
        HStack(alignment: .top, spacing: 12) {
            statCard(title: "Active Policy",
                     value: store.globalProxyPolicy.isEmpty ? "—" : store.globalProxyPolicy,
                     caption: activePolicyCaption,
                     trailing: AnyView(HStack(spacing: 6) {
                         Chip(text: "RULE · \(store.proxyRoutingMode.title.uppercased())", tone: .accent, monospaced: true)
                         Spacer()
                         Chip(text: "⌘ P", monospaced: true)
                     }),
                     pulse: store.localProxyRunning ? .accent : .neutral)

            statCard(title: "Rules Loaded",
                     value: formatCount(store.profile.rules.count),
                     caption: "\(store.profile.rules.filter { $0.type == "RULE-SET" }.count) RULE-SET sources · \(store.proxyRuleStats.count) matched today",
                     trailing: AnyView(HStack(spacing: 6) {
                         Chip(text: "DOMAIN · \(store.profile.rules.filter { $0.type.hasPrefix("DOMAIN") }.count)", monospaced: true)
                         Chip(text: "IP-CIDR · \(store.profile.rules.filter { $0.type.hasPrefix("IP-CIDR") }.count)", monospaced: true)
                     }),
                     pulse: nil)

            statCard(title: "Surge",
                     value: surgeValue,
                     caption: surgeCaption,
                     trailing: AnyView(Chip(text: "com.nssurge.surge-mac", monospaced: true)),
                     pulse: .neutral)
        }
    }

    private var activePolicyCaption: String {
        if let latest = store.connectivityTestResults.compactMap(\.durationMilliseconds).first {
            return "leaf · \(latest) ms last probed"
        }
        return store.profile.proxies.first(where: { $0.name == store.globalProxyPolicy }).map { "\($0.kind.rawValue.uppercased())" } ?? "·"
    }

    private var surgeValue: String {
        if store.surgeAppSnapshot.isRunning { return "Running" }
        return "Standby"
    }
    private var surgeCaption: String {
        store.surgeAppSnapshot.networkTunnelStatus
    }

    private func statCard(title: String, value: String, caption: String, trailing: AnyView, pulse: ChipTone?) -> some View {
        BlazeCard {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title.uppercased())
                        .font(BlazeUI.captionFont)
                        .kerning(0.8)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if let pulse {
                        Circle().fill(color(for: pulse)).frame(width: 6, height: 6)
                            .overlay(Circle().stroke(color(for: pulse).opacity(0.3), lineWidth: 3).scaleEffect(1.7))
                    }
                }
                Text(value)
                    .font(.system(size: 19, weight: .semibold))
                    .lineLimit(1)
                Text(caption)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 6)
                trailing
            }
        }
        .frame(minHeight: 96, alignment: .topLeading)
    }

    private func color(for tone: ChipTone) -> Color {
        switch tone {
        case .positive: .blazePositive
        case .warning: .blazeWarning
        case .danger: .blazeDanger
        case .accent: .blazeAccent
        case .purple: .blazePurple
        case .neutral: .secondary
        }
    }

    @ViewBuilder private var twoCol: some View {
        HStack(alignment: .top, spacing: 12) {
            BlazePanel(title: "Latency leaderboard",
                       accessory: AnyView(HStack(spacing: 6) {
                           Button("Refresh") { Task { await store.runLatencyChecks() } }
                               .buttonStyle(.plain).foregroundStyle(Color.blazeAccent).font(.system(size: 11))
                           KBDPill(label: "⌘ R")
                       })) {
                latencyRows
            }
            BlazePanel(title: "Recent connections",
                       accessory: AnyView(HStack(spacing: 6) {
                           Text("View all").foregroundStyle(Color.blazeAccent).font(.system(size: 11))
                           KBDPill(label: "⌘ T")
                       })) {
                recentRows
            }
        }
    }

    @ViewBuilder private var latencyRows: some View {
        let proxies = store.profile.proxies
            .sorted { lhs, rhs in
                let l = store.latencyResults[lhs.name]?.milliseconds ?? .max
                let r = store.latencyResults[rhs.name]?.milliseconds ?? .max
                return l < r
            }
            .prefix(6)

        let maxMs = max(1, proxies.compactMap { store.latencyResults[$0.name]?.milliseconds }.max() ?? 200)

        VStack(alignment: .leading, spacing: 0) {
            if proxies.isEmpty {
                emptyState("No proxies imported", "Import a profile to see latency.")
            } else {
                ForEach(Array(proxies.enumerated()), id: \.element.id) { (idx, proxy) in
                    let ms = store.latencyResults[proxy.name]?.milliseconds
                    let tone: ChipTone = (ms.map { $0 > 180 ? .danger : ($0 > 130 ? .warning : .positive) }) ?? .neutral
                    latencyRow(
                        proxy: proxy,
                        ms: ms,
                        tone: tone,
                        widthFraction: ms.map { Double(min($0, maxMs)) / Double(maxMs) } ?? 1.0,
                        highlighted: idx == 0
                    )
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
    }

    @ViewBuilder private func latencyRow(proxy: ProxyNode, ms: Int?, tone: ChipTone, widthFraction: Double, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Text(displayFlag(for: proxy)).font(.system(size: 14))
            VStack(alignment: .leading, spacing: 1) {
                Text(proxy.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text("\(proxy.kind.rawValue) · \(proxy.port.map { String($0) } ?? "")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.blazeTextSecondary.opacity(0.1)).frame(height: 4)
                    Capsule()
                        .fill(latencyGradient(tone))
                        .frame(width: max(8, geo.size.width * (ms == nil ? 1.0 : widthFraction)), height: 4)
                }
            }
            .frame(width: 80, height: 6)
            Text(ms.map { "\($0)" } ?? "—")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(ms == nil ? .red : .primary)
            Text("ms").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(highlighted ? Color.blazeAccent.opacity(0.10) : .clear)
        )
    }

    private func latencyGradient(_ tone: ChipTone) -> LinearGradient {
        switch tone {
        case .danger:
            return LinearGradient(colors: [.blazeWarning, .blazeDanger], startPoint: .leading, endPoint: .trailing)
        case .warning:
            return LinearGradient(colors: [.blazePositive, .blazeWarning], startPoint: .leading, endPoint: .trailing)
        default:
            return LinearGradient(colors: [.blazePositive, Color(red: 0.42, green: 0.83, blue: 0.5)], startPoint: .leading, endPoint: .trailing)
        }
    }

    @ViewBuilder private var recentRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.proxyEvents.isEmpty {
                emptyState("No traffic yet", "leaf will surface every connection here.")
            } else {
                ForEach(Array(store.proxyEvents.prefix(6))) { event in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(eventColor(for: event))
                            .frame(width: 8, height: 8)
                        Text(event.host == "-" ? event.target : "\(event.host):\(event.port)")
                            .font(.system(size: 11.5, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Chip(text: shortPolicy(event.policy), tone: .accent, monospaced: false)
                        Text(noteSnippet(event.note))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text(relativeTimestamp(event.date))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Divider().background(Color.blazeBorder.opacity(0.3)), alignment: .bottom)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
    }

    private func eventColor(for event: ProxyServerEvent) -> Color {
        switch event.status.lowercased() {
        case "connected", "passed": return .blazePositive
        case "failed", "rejected": return .blazeDanger
        case "warn", "warning", "closed": return .blazeWarning
        default: return .blazeAccent
        }
    }

    private func shortPolicy(_ policy: String) -> String {
        let trimmed = policy.replacingOccurrences(of: "🇭🇰 ", with: "")
            .replacingOccurrences(of: "🇸🇬 ", with: "")
            .replacingOccurrences(of: "🇯🇵 ", with: "")
        return trimmed.count > 16 ? String(trimmed.prefix(16)) + "…" : trimmed
    }

    private func noteSnippet(_ note: String) -> String {
        guard let connectIdx = note.range(of: "connect=") else { return "" }
        let tail = note[connectIdx.upperBound...]
        if let end = tail.range(of: " ") {
            return String(tail[..<end.lowerBound])
        }
        return String(tail)
    }

    @ViewBuilder private var selfTest: some View {
        BlazeCard(padding: 12) {
            HStack(spacing: 6) {
                ForEach(Array(store.startupWorkflowSteps.enumerated()), id: \.element.id) { (idx, step) in
                    if idx > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    selfTestPill(step)
                }
                Spacer()
                HStack(spacing: 5) {
                    Button("Run again") {
                        Task { await store.runStartupWorkflow() }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.blazeAccent)
                    .font(.system(size: 11.5, weight: .medium))
                    KBDPill(label: "⌘⇧ R")
                }
            }
        }
    }

    @ViewBuilder private func selfTestPill(_ step: StartupWorkflowStep) -> some View {
        let (tone, label): (ChipTone, String) = stepTone(step)
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(color(for: tone)).frame(width: 12, height: 12)
                Image(systemName: stepIcon(step))
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(.white)
            }
            Text(stepShortName(step))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tone == .neutral ? .secondary : .primary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color(for: tone).opacity(0.16))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.blazeBorder.opacity(0.4), lineWidth: 0.5))
        .help(label)
    }

    private func stepTone(_ step: StartupWorkflowStep) -> (ChipTone, String) {
        switch step.status {
        case .passed: (.positive, "Passed · \(step.detail)")
        case .failed: (.danger, "Failed · \(step.detail)")
        case .running: (.accent, "Running · \(step.detail)")
        case .actionNeeded: (.warning, "Action needed · \(step.detail)")
        case .info: (.neutral, step.detail)
        case .pending: (.neutral, step.detail)
        }
    }

    private func stepIcon(_ step: StartupWorkflowStep) -> String {
        switch step.status {
        case .passed: "checkmark"
        case .failed: "xmark"
        case .running: "circle.dotted"
        case .actionNeeded: "exclamationmark"
        case .info, .pending: ""
        }
    }

    private func stepShortName(_ step: StartupWorkflowStep) -> String {
        // First word or two of the title
        let parts = step.title.split(separator: " ", maxSplits: 2)
        if parts.count >= 2 { return "\(parts[0]) \(parts[1])" }
        return step.title
    }

    @ViewBuilder private func emptyState(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Traffic page (live connection feed)

struct TrafficPage: View {
    @EnvironmentObject var store: WorkbenchStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            filterBar
            statsStrip
            HStack(alignment: .top, spacing: 12) {
                connectionsPanel
                sidePanel
            }
        }
        .padding(20)
    }

    @ViewBuilder private var filterBar: some View {
        BlazeCard(padding: 8) {
            HStack(spacing: 8) {
                segmented(["5 min", "1 hour", "24 hours", "All"], selected: 1)
                Divider().frame(height: 18)
                segmented(["All", "Connected", "Closed", "Failed"], selected: 0)
                Divider().frame(height: 18)
                policyPicker
                Spacer()
                tinyButton("Export", icon: "square.and.arrow.down", accent: true)
            }
        }
    }

    @ViewBuilder private func segmented(_ items: [String], selected: Int) -> some View {
        HStack(spacing: 1) {
            ForEach(Array(items.enumerated()), id: \.offset) { (idx, item) in
                Text(item)
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .foregroundStyle(idx == selected ? .primary : .secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(idx == selected ? Color(nsColor: .windowBackgroundColor) : .clear)
                    )
            }
        }
        .padding(2)
        .background(Color.blazeTile)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.blazeBorder.opacity(0.5), lineWidth: 0.5))
    }

    @ViewBuilder private var policyPicker: some View {
        HStack(spacing: 6) {
            Text(store.globalProxyPolicy.isEmpty ? "All policies" : store.globalProxyPolicy)
                .font(.system(size: 12))
            Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Color.blazeTile)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.blazeBorder.opacity(0.5), lineWidth: 0.5))
    }

    @ViewBuilder private func tinyButton(_ label: String, icon: String, accent: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11))
            Text(label).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(accent ? Color.blazeAccent : .secondary)
        .padding(.horizontal, 9)
        .frame(height: 24)
    }

    @ViewBuilder private var statsStrip: some View {
        let total = store.proxyEvents.count
        let connected = store.proxyEvents.filter { $0.status.lowercased() == "connected" }.count
        let failed = store.proxyEvents.filter { $0.status.lowercased() == "failed" }.count

        HStack(spacing: 10) {
            statsCell(label: "Active", value: "\(connected)", delta: "live", tone: .positive)
            statsCell(label: "Today", value: "\(total)", delta: "↑ 18% vs yesterday", tone: .neutral)
            statsCell(label: "Bytes ↑", value: "4.2 MB", delta: "avg 12.4 KB/s", tone: .neutral)
            statsCell(label: "Bytes ↓", value: "18.7 MB", delta: "avg 47.1 KB/s", tone: .neutral)
            statsCell(label: "Fail rate",
                      value: total == 0 ? "0.0 %" : String(format: "%.1f %%", Double(failed) / Double(total) * 100),
                      delta: "\(failed) of \(total)", tone: failed > 0 ? .danger : .neutral)
        }
    }

    @ViewBuilder private func statsCell(label: String, value: String, delta: String, tone: ChipTone) -> some View {
        BlazeCard(padding: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label.uppercased()).font(BlazeUI.captionFont).kerning(0.8).foregroundStyle(.tertiary)
                Text(value).font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tone == .danger ? .red : .primary)
                Text(delta).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var connectionsPanel: some View {
        BlazePanel(title: "Live connections") {
            HStack(spacing: 10) {
                col("Time", width: 60)
                col("Host", width: nil)
                col("Policy", width: 80)
                col("Rule", width: 110)
                col("Bytes", width: 80)
                col("Status", width: 80)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
            .overlay(Divider().background(Color.blazeBorder.opacity(0.4)), alignment: .bottom)

            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(store.proxyEvents.prefix(40))) { event in
                        connectionRow(event)
                    }
                }
            }
            .frame(minHeight: 360, maxHeight: 460)
        }
    }

    @ViewBuilder private func col(_ text: String, width: CGFloat?) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(.tertiary)
            .frame(width: width, alignment: text == "Bytes" ? .trailing : .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    @ViewBuilder private func connectionRow(_ event: ProxyServerEvent) -> some View {
        let bytes = bytesFromNote(event.note)
        HStack(spacing: 10) {
            Text(timeOnly(event.date))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .leading)

            Text(event.host == "-" ? event.target : "\(event.host):\(event.port)")
                .font(.system(size: 11.5, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)

            Chip(text: shortPolicy(event.policy), tone: .accent)
                .frame(width: 80, alignment: .center)

            Text(event.rule ?? "—")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)

            Text(bytes)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

            HStack(spacing: 5) {
                Circle().fill(statusColor(event.status)).frame(width: 7, height: 7)
                Text(event.status.lowercased()).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .frame(width: 80, alignment: .leading)

            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .overlay(Divider().background(Color.blazeBorder.opacity(0.3)), alignment: .bottom)
    }

    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "connected", "passed": .blazePositive
        case "failed", "rejected": .blazeDanger
        case "closed", "warn", "warning": .blazeWarning
        default: .blazeAccent
        }
    }

    private func bytesFromNote(_ note: String) -> String {
        if let range = note.range(of: #"tunnel ([\d.]+ ?[KMG]?[iI]?B) up / ([\d.]+ ?[KMG]?[iI]?B) down"#, options: .regularExpression) {
            return String(note[range]).replacingOccurrences(of: "tunnel ", with: "")
        }
        return "—"
    }

    @ViewBuilder private var sidePanel: some View {
        VStack(spacing: 12) {
            BlazePanel(title: "Policy breakdown") {
                policyBreakdown.padding(.horizontal, 14).padding(.bottom, 12)
            }
            BlazePanel(title: "Top destinations") {
                topDestinations.padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
        .frame(width: 280)
    }

    @ViewBuilder private var policyBreakdown: some View {
        if store.proxyPolicyStats.isEmpty {
            Text("No connections yet").font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.vertical, 24).frame(maxWidth: .infinity)
        } else {
            let total = max(1, store.proxyPolicyStats.reduce(0) { $0 + $1.count })
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(store.proxyPolicyStats.prefix(5))) { stat in
                    HStack(spacing: 7) {
                        Circle().fill(donutColor(for: stat.policy)).frame(width: 9, height: 9)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                        Text(shortPolicy(stat.policy)).font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text("\(Int(Double(stat.count) / Double(total) * 100))%")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var topDestinations: some View {
        let hosts = Dictionary(grouping: store.proxyEvents, by: { $0.host })
            .map { (host: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
            .prefix(6)
        if hosts.isEmpty {
            Text("No destinations yet").font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 12)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(hosts.enumerated()), id: \.offset) { (_, item) in
                    HStack {
                        Text(item.host)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Text("\(item.count)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 5)
                    .overlay(Divider().background(Color.blazeBorder.opacity(0.3)), alignment: .bottom)
                }
            }
        }
    }

    private func donutColor(for policy: String) -> Color {
        if policy.contains("DIRECT") { return .blazePositive }
        if policy.contains("REJECT") { return .blazeDanger }
        if policy.contains("HK 10") { return .blazeAccent }
        if policy.contains("HK 02") { return .blazeWarning }
        return .blue
    }

    private func shortPolicy(_ s: String) -> String {
        let trimmed = s.replacingOccurrences(of: "🇭🇰 ", with: "")
            .replacingOccurrences(of: "🇸🇬 ", with: "")
            .replacingOccurrences(of: "🇯🇵 ", with: "")
        return trimmed.count > 18 ? String(trimmed.prefix(18)) + "…" : trimmed
    }
}

// MARK: - Policies page

struct PoliciesPage: View {
    @EnvironmentObject var store: WorkbenchStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            filterBar
            policyGrid
            groupsPanel
        }
        .padding(20)
    }

    @ViewBuilder private var filterBar: some View {
        BlazeCard(padding: 8) {
            HStack(spacing: 8) {
                Text("All · \(store.profile.proxies.count)")
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Color(nsColor: .windowBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 4))
                Text("Trojan · \(store.profile.proxies.filter { $0.kind == .trojan }.count)")
                    .font(.system(size: 11.5)).padding(.horizontal, 9).padding(.vertical, 3).foregroundStyle(.secondary)
                Text("Shadowsocks · \(store.profile.proxies.filter { $0.kind == .shadowsocks }.count)")
                    .font(.system(size: 11.5)).padding(.horizontal, 9).padding(.vertical, 3).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await store.runLatencyChecks() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "bolt.fill").font(.system(size: 10))
                        Text("Probe all").font(.system(size: 11.5, weight: .medium))
                        KBDPill(label: "⌘ R")
                    }
                    .foregroundStyle(Color.blazeAccent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var policyGrid: some View {
        let proxies = store.profile.proxies
        if proxies.isEmpty {
            BlazeCard {
                VStack(spacing: 8) {
                    Image(systemName: "globe").font(.system(size: 22)).foregroundStyle(.tertiary)
                    Text("No proxies imported").font(.system(size: 13, weight: .medium))
                    Text("Drop a profile URL into Settings to begin.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(proxies.prefix(12)) { proxy in
                    policyCard(proxy)
                }
            }
        }
    }

    @ViewBuilder private func policyCard(_ proxy: ProxyNode) -> some View {
        let current = proxy.name == store.globalProxyPolicy
        let ms = store.latencyResults[proxy.name]?.milliseconds
        let tone: ChipTone = (ms.map { $0 > 180 ? .danger : ($0 > 130 ? .warning : .positive) }) ?? .neutral
        Button {
            store.setGlobalProxyPolicy(proxy.name)
        } label: {
            BlazeCard(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text(displayFlag(for: proxy)).font(.system(size: 22))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(proxy.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text("\(proxy.kind.rawValue) · \(proxy.port.map { String($0) } ?? "")")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(ms.map { "\($0)" } ?? (proxy.kind == .direct ? "—" : "?"))
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                            .foregroundStyle(tone == .danger ? .red : (tone == .warning ? .orange : .primary))
                        Text("ms").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    HStack {
                        HStack(spacing: 6) {
                            Circle().fill(current ? Color.blazePositive : Color.blazeTextTertiary).frame(width: 6, height: 6)
                            Text(current ? "Selected" : "Idle").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if current { Chip(text: "SELECTED", tone: .accent) }
                    }
                    .padding(.top, 4)
                    .overlay(Divider().background(Color.blazeBorder.opacity(0.4)), alignment: .top)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: BlazeUI.cardRadius)
                    .strokeBorder(current ? Color.blazeAccent : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var groupsPanel: some View {
        if !store.profile.groups.isEmpty {
            BlazePanel(title: "Proxy groups") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.profile.groups) { group in
                        HStack(spacing: 12) {
                            HStack(spacing: 8) {
                                Text(group.name).font(.system(size: 12.5, weight: .medium))
                                Text(group.kind.rawValue)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text("\(group.policies.count) members")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                Text(store.selectedPolicies[group.name] ?? group.policies.first ?? "—")
                                    .font(.system(size: 11.5))
                                    .lineLimit(1)
                                Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color.blazeTile)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.blazeBorder.opacity(0.5), lineWidth: 0.5))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .overlay(Divider().background(Color.blazeBorder.opacity(0.3)), alignment: .bottom)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }
}

// MARK: - Rules page

struct RulesPage: View {
    @EnvironmentObject var store: WorkbenchStore
    @State private var query: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            kindFilter
            HStack(alignment: .top, spacing: 12) {
                listPanel
                testerPanel
            }
        }
        .padding(20)
    }

    private var rules: [ProxyRule] { store.profile.rules }

    private var kindCounts: [(String, Int)] {
        let groups = Dictionary(grouping: rules, by: { $0.type })
        return groups.map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }.prefix(6).map { $0 }
    }

    @ViewBuilder private var kindFilter: some View {
        BlazeCard(padding: 8) {
            HStack(spacing: 8) {
                Text("All · \(rules.count)").font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Color(nsColor: .windowBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 4))
                ForEach(kindCounts, id: \.0) { (kind, count) in
                    Text("\(kind) · \(count)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                }
                Spacer()
                Button {
                    Task { await store.importRuleSets() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                        Text("Refresh sources").font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var listPanel: some View {
        BlazePanel(title: "Rules · showing \(min(40, rules.count)) of \(rules.count)") {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rules.prefix(40))) { rule in
                        ruleRow(rule)
                    }
                }
            }
            .frame(minHeight: 400, maxHeight: 460)
        }
    }

    @ViewBuilder private func ruleRow(_ rule: ProxyRule) -> some View {
        HStack(spacing: 12) {
            ruleKindBadge(rule.type)
            Text(rule.value.isEmpty ? "·" : rule.value)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            ruleTargetChip(rule.policy)
            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .overlay(Divider().background(Color.blazeBorder.opacity(0.3)), alignment: .bottom)
    }

    @ViewBuilder private func ruleKindBadge(_ type: String) -> some View {
        let tone: ChipTone = ruleKindTone(type)
        Text(shortKind(type))
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .kerning(0.4)
            .foregroundStyle(ruleKindColor(tone))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(ruleKindColor(tone).opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: BlazeUI.chipRadius))
            .frame(width: 110, alignment: .center)
    }

    private func ruleKindTone(_ type: String) -> ChipTone {
        if type.hasPrefix("DOMAIN") { return .accent }
        if type.hasPrefix("IP-CIDR") { return .positive }
        if type == "GEOIP" { return .warning }
        if type == "DEST-PORT" { return .purple }
        if type == "FINAL" || type == "MATCH" { return .neutral }
        if type == "URL-REGEX" { return .danger }
        return .neutral
    }

    private func ruleKindColor(_ tone: ChipTone) -> Color {
        switch tone {
        case .accent: .blazeAccent
        case .positive: .blazePositive
        case .warning: .blazeWarning
        case .purple: .blazePurple
        case .danger: .blazeDanger
        default: .blazeTextSecondary
        }
    }

    private func shortKind(_ type: String) -> String {
        switch type {
        case "DOMAIN-SUFFIX": "DOMAIN-SFX"
        case "DOMAIN-KEYWORD": "DOMAIN-KW"
        case "URL-REGEX": "URL-REGEX"
        default: type
        }
    }

    @ViewBuilder private func ruleTargetChip(_ policy: String) -> some View {
        let tone: ChipTone = policy == "DIRECT" ? .neutral : (policy.contains("REJECT") ? .danger : .accent)
        Chip(text: shortPolicy(policy), tone: tone)
            .frame(width: 130, alignment: .trailing)
    }

    private func shortPolicy(_ s: String) -> String {
        let trimmed = s.replacingOccurrences(of: "🇭🇰 ", with: "")
            .replacingOccurrences(of: "🇸🇬 ", with: "")
        return trimmed.count > 18 ? String(trimmed.prefix(18)) + "…" : trimmed
    }

    @ViewBuilder private var testerPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            BlazeCard(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("LIVE TEST")
                        .font(BlazeUI.captionFont).kerning(0.8).foregroundStyle(.tertiary)
                    HStack {
                        TextField("host:port", text: $query)
                            .font(.system(size: 12, design: .monospaced))
                            .textFieldStyle(.plain)
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.blazeTile)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.blazeBorder.opacity(0.5), lineWidth: 0.5))

                    if !query.isEmpty {
                        evaluationView
                    } else {
                        Text("Type any host to see which rule wins.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(width: 300)
    }

    @ViewBuilder private var evaluationView: some View {
        let result = RouteProbe(profile: store.profile, groupSelections: store.selectedPolicies).evaluate(query)
        VStack(alignment: .leading, spacing: 6) {
            Text("MATCHED").font(BlazeUI.captionFont).foregroundStyle(.tertiary)
            HStack(spacing: 6) {
                Text(result.rule.isEmpty ? "FINAL" : result.rule)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                Text("→").foregroundStyle(.tertiary)
                Chip(text: shortPolicy(result.policy.isEmpty ? result.policyPath : result.policy), tone: .accent)
            }
            Text(result.reason)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .background(Color.blazeAccent.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Diagnostics page

struct DiagnosticsPage: View {
    @EnvironmentObject var store: WorkbenchStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            actionBar
            HStack(alignment: .top, spacing: 12) {
                timelinePanel
                rightCol
            }
        }
        .padding(20)
    }

    @ViewBuilder private var actionBar: some View {
        BlazeCard(padding: 8) {
            HStack(spacing: 10) {
                Text("Startup self-test").font(.system(size: 12, weight: .semibold))
                Text(actionSubtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await store.runStartupWatchdogRecoveryNow() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill").font(.system(size: 10))
                        Text("Force recovery").font(.system(size: 11.5, weight: .medium))
                    }.foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Button {
                    Task { await store.runStartupWorkflow() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill").font(.system(size: 10))
                        Text("Run again").font(.system(size: 11.5, weight: .medium))
                        KBDPill(label: "⌘⇧ R")
                    }
                    .foregroundStyle(Color.blazeAccent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var actionSubtitle: String {
        if store.startupWorkflowRunning { return "Running · \(store.startupWatchdogText)" }
        return store.startupWatchdogText.isEmpty ? "Idle" : store.startupWatchdogText
    }

    @ViewBuilder private var timelinePanel: some View {
        BlazePanel(title: "Startup workflow") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(store.startupWorkflowSteps) { step in
                    timelineRow(step)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .frame(width: 360)
    }

    @ViewBuilder private func timelineRow(_ step: StartupWorkflowStep) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(stepColor(step)).frame(width: 22, height: 22)
                Image(systemName: stepIcon(step)).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(step.title).font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Text(stepStatusText(step)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                }
                Text(step.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 6)
    }

    private func stepColor(_ step: StartupWorkflowStep) -> Color {
        switch step.status {
        case .passed: .blazePositive
        case .failed: .blazeDanger
        case .running: .blazeAccent
        case .actionNeeded: .blazeWarning
        case .info: Color.blazeTextTertiary
        case .pending: Color.blazeTextTertiary.opacity(0.5)
        }
    }
    private func stepIcon(_ step: StartupWorkflowStep) -> String {
        switch step.status {
        case .passed: "checkmark"
        case .failed: "xmark"
        case .running: "circle.dotted"
        case .actionNeeded: "exclamationmark"
        case .info: "info"
        case .pending: "clock"
        }
    }
    private func stepStatusText(_ step: StartupWorkflowStep) -> String {
        switch step.status {
        case .passed: "passed"
        case .failed: "failed"
        case .running: "running"
        case .actionNeeded: "action"
        case .info: "info"
        case .pending: "pending"
        }
    }

    @ViewBuilder private var rightCol: some View {
        VStack(spacing: 12) {
            counterGrid
            dnsCard
            logTail
        }
    }

    @ViewBuilder private var counterGrid: some View {
        let diag = store.packetTunnelDiagnosticsSnapshot
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
            counter(label: "Packets", value: diag.map { String($0.packetsRead) } ?? "—", sub: diag.map { "TCP \($0.tcpPackets) · DNS \($0.dnsQueries)" } ?? "")
            counter(label: "HEV in/out", value: diag.map { "\($0.hevPacketsSentToTunnel) / \($0.hevPacketsReceivedFromTunnel)" } ?? "—", sub: diag.map { "bridge errors \($0.hevBridgeWriteFailures)" } ?? "")
            counter(label: "Active TCP", value: diag.map { String($0.activeTCPFlows) } ?? "0", sub: diag.map { "fake-IP \($0.fakeIPTCPDestinations)" } ?? "")
            counter(label: "Retransmits", value: diag.map { String($0.tcpRetransmittedPackets) } ?? "0", sub: "tcp packets", tone: (diag?.tcpRetransmittedPackets ?? 0) > 0 ? .warning : .neutral)
        }
    }

    @ViewBuilder private func counter(label: String, value: String, sub: String, tone: ChipTone = .neutral) -> some View {
        BlazeCard(padding: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label.uppercased()).font(.system(size: 9.5, weight: .semibold)).kerning(1.0).foregroundStyle(.tertiary)
                Text(value).font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tone == .warning ? .orange : (tone == .danger ? .red : .primary))
                Text(sub).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var dnsCard: some View {
        BlazePanel(title: "DNS · FakeIP") {
            VStack(alignment: .leading, spacing: 4) {
                kvRow("Mode", "FakeIP · 198.18.0.0/15")
                kvRow("Tunnel DNS", "198.19.0.1 → https://1.1.1.1/dns-query")
                kvRow("DoH bypass", "en1 · 1.1.1.1, 8.8.8.8, 223.5.5.5")
                kvRow("Upstream A", "03bfbe3155… → 43.132.133.175 · TTL 60s")
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }
    @ViewBuilder private func kvRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.system(size: 11.5)).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(v).font(.system(size: 11, design: .monospaced)).foregroundStyle(.primary).lineLimit(2)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var logTail: some View {
        BlazePanel(title: "Recent events") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(store.proxyEvents.prefix(8))) { event in
                    HStack(spacing: 12) {
                        Text(timeOnly(event.date))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 70, alignment: .leading)
                        Text(event.status.uppercased())
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(eventColor(for: event).opacity(0.18))
                            .foregroundStyle(eventColor(for: event))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .frame(width: 55, alignment: .center)
                        Text(event.note.isEmpty ? event.target : event.note)
                            .font(.system(size: 10.5, design: .monospaced))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .overlay(Divider().background(Color.blazeBorder.opacity(0.3)), alignment: .bottom)
                }
            }
        }
    }

    private func eventColor(for event: ProxyServerEvent) -> Color {
        switch event.status.lowercased() {
        case "connected", "passed": .blazePositive
        case "failed", "rejected": .blazeDanger
        case "warn", "warning", "closed": .blazeWarning
        default: .blazeAccent
        }
    }
}

// MARK: - Settings page

struct SettingsPage: View {
    @EnvironmentObject var store: WorkbenchStore
    @State private var selected: String = "profile"

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            settingsNav
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    profileSection
                    engineSection
                    routingSection
                    systemSection
                    aboutSection
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(20)
    }

    @ViewBuilder private var settingsNav: some View {
        VStack(alignment: .leading, spacing: 2) {
            navRow("Profile", id: "profile", icon: "doc.text")
            navRow("Engine", id: "engine", icon: "cpu")
            navRow("Routing", id: "routing", icon: "globe")
            navRow("System", id: "system", icon: "shield")
            navRow("Logging", id: "logging", icon: "list.bullet")
            navRow("Updates", id: "updates", icon: "arrow.down.circle")
            navRow("About", id: "about", icon: "info.circle")
        }
        .frame(width: 200, alignment: .leading)
    }

    @ViewBuilder private func navRow(_ label: String, id: String, icon: String) -> some View {
        Button { selected = id } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(selected == id ? .primary : .secondary)
                Text(label).font(.system(size: 12.5, weight: selected == id ? .medium : .regular)).foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected == id ? Color.primary.opacity(0.06) : .clear))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var profileSection: some View {
        settingsSection(title: "Profile source", desc: "Where Blaze reads its proxy nodes, groups, and rules from.") {
            formRow(label: "Managed config URL") {
                Text(store.remoteProfileURLText.isEmpty ? "—" : store.remoteProfileURLText)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Reveal") {}.buttonStyle(.bordered).controlSize(.small)
            }
            formRow(label: "Auto-refresh", hint: "Re-fetch the managed URL on this interval") {
                Spacer()
                pickerLike("12 hours")
            }
            formRow(label: "Last fetch") {
                Text(profileSummary)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Refresh now") {
                    Task { await store.importRemoteProfileAndRuleSets() }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(store.remoteImportInProgress)
            }
        }
    }

    private var profileSummary: String {
        "\(store.profile.proxies.count) proxies · \(store.profile.groups.count) groups · \(formatCount(store.profile.rules.count)) rules"
    }

    @ViewBuilder private var engineSection: some View {
        settingsSection(title: "Engine · leaf", desc: "The embedded Rust proxy. Restarting applies new port/log settings.") {
            formRow(label: "HTTP port") { Spacer(); fieldLike("\(store.proxyListenPort)") }
            formRow(label: "SOCKS5 port") { Spacer(); fieldLike("\(store.socksListenPort)") }
            formRow(label: "Log level") {
                Spacer()
                radioGroup(["error", "warn", "info", "debug", "trace"], selected: 2)
            }
        }
    }

    @ViewBuilder private var routingSection: some View {
        settingsSection(title: "Routing", desc: "How leaf decides which policy receives each connection.") {
            formRow(label: "Mode") {
                Spacer()
                radioGroup(["Direct", "Global", "Rule-based"], selected: routingIndex)
            }
            formRow(label: "Fallback policy", hint: "Used by FINAL when the profile has none") {
                Spacer()
                pickerLike(store.globalProxyPolicy.isEmpty ? "—" : store.globalProxyPolicy)
            }
        }
    }

    private var routingIndex: Int {
        switch store.proxyRoutingMode {
        case .direct: 0
        case .global: 1
        case .ruleBased: 2
        }
    }

    @ViewBuilder private var systemSection: some View {
        settingsSection(title: "System handoff", desc: "Coordinate with Surge and the macOS system proxy.") {
            formRow(label: "Stop Surge before starting", hint: "Avoid DNS / utun ownership conflict") {
                Spacer(); Toggle("", isOn: .constant(true)).labelsHidden().toggleStyle(.switch)
            }
            formRow(label: "Restore Surge on shutdown") {
                Spacer(); Toggle("", isOn: .constant(true)).labelsHidden().toggleStyle(.switch)
            }
            formRow(label: "Watchdog timeout") {
                Spacer(); pickerLike("5 minutes")
            }
            formRow(label: "Telegram ping on recovery", hint: "Send 继续 prompt to your chat") {
                Spacer(); Toggle("", isOn: .constant(true)).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    @ViewBuilder private var aboutSection: some View {
        settingsSection(title: "About", desc: "") {
            formRow(label: "Version") {
                Text("0.1.0 · build 62 · arm64")
                    .font(.system(size: 11.5, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Check for update") {}.buttonStyle(.bordered).controlSize(.small)
            }
            formRow(label: "Components") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("leaf 0.14.2 · 7a9101b5 (Apache-2.0)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    Text("hev-socks5-tunnel · 3ffa5b91 (MIT)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    Text("swift 6.1.2 · macOS 15.0 SDK").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            formRow(label: "Signing") {
                Text("Developer ID Application · HYF3XBWBL2 · Notarized")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func settingsSection(title: String, desc: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 4)
            if !desc.isEmpty {
                Text(desc).font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 10)
            } else {
                Spacer().frame(height: 4)
            }
            content()
        }
        .background(Color.blazeCard)
        .clipShape(RoundedRectangle(cornerRadius: BlazeUI.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: BlazeUI.panelRadius).strokeBorder(Color.blazeBorder.opacity(0.55), lineWidth: 0.5))
    }

    @ViewBuilder private func formRow<Content: View>(label: String, hint: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 12.5))
                if let hint { Text(hint).font(.system(size: 10.5)).foregroundStyle(.tertiary) }
            }
            .frame(width: 160, alignment: .leading)
            content()
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .overlay(Divider().background(Color.blazeBorder.opacity(0.3)), alignment: .top)
    }

    @ViewBuilder private func fieldLike(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .padding(.horizontal, 10).frame(height: 26)
            .background(Color.blazeTile)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.blazeBorder.opacity(0.5), lineWidth: 0.5))
    }

    @ViewBuilder private func pickerLike(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 12))
            Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(Color.blazeTile)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.blazeBorder.opacity(0.5), lineWidth: 0.5))
    }

    @ViewBuilder private func radioGroup(_ items: [String], selected: Int) -> some View {
        HStack(spacing: 1) {
            ForEach(Array(items.enumerated()), id: \.offset) { (idx, item) in
                Text(item)
                    .font(.system(size: 11.5, weight: idx == selected ? .medium : .regular))
                    .padding(.horizontal, 11).padding(.vertical, 4)
                    .foregroundStyle(idx == selected ? .primary : .secondary)
                    .background(RoundedRectangle(cornerRadius: 4).fill(idx == selected ? Color(nsColor: .windowBackgroundColor) : .clear))
            }
        }
        .padding(2)
        .background(Color.blazeTile)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.blazeBorder.opacity(0.5), lineWidth: 0.5))
    }
}

// MARK: - Helpers

struct IconLeadingStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            configuration.title
        }
    }
}

struct BlazeSparkline: View {
    let points: [Double] = [0.65, 0.55, 0.6, 0.4, 0.5, 0.3, 0.42, 0.32, 0.3, 0.45, 0.36, 0.55, 0.48, 0.7, 0.58, 0.62, 0.5, 0.55, 0.4, 0.5]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Path { p in
                    let xStep = geo.size.width / CGFloat(points.count - 1)
                    p.move(to: .init(x: 0, y: geo.size.height))
                    for (i, value) in points.enumerated() {
                        let x = CGFloat(i) * xStep
                        let y = geo.size.height * (1 - CGFloat(value))
                        if i == 0 {
                            p.move(to: .init(x: 0, y: y))
                        } else {
                            p.addLine(to: .init(x: x, y: y))
                        }
                    }
                    p.addLine(to: .init(x: geo.size.width, y: geo.size.height))
                    p.addLine(to: .init(x: 0, y: geo.size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [Color.blazeAccent.opacity(0.25), Color.blazeAccent.opacity(0)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    let xStep = geo.size.width / CGFloat(points.count - 1)
                    for (i, value) in points.enumerated() {
                        let x = CGFloat(i) * xStep
                        let y = geo.size.height * (1 - CGFloat(value))
                        if i == 0 {
                            p.move(to: .init(x: x, y: y))
                        } else {
                            p.addLine(to: .init(x: x, y: y))
                        }
                    }
                }
                .stroke(Color.blazeAccent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

private func formatCount(_ n: Int) -> String {
    if n >= 1000 {
        let v = Double(n) / 1000.0
        return v.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(v))k" : String(format: "%.1fk", v)
    }
    return "\(n)"
}

private func displayFlag(for proxy: ProxyNode) -> String {
    let lower = proxy.name.lowercased()
    if lower.contains("hong kong") || lower.contains("🇭🇰") || lower.contains("hk") { return "🇭🇰" }
    if lower.contains("singapore") || lower.contains("🇸🇬") || lower.contains("sg") { return "🇸🇬" }
    if lower.contains("tokyo") || lower.contains("🇯🇵") || lower.contains("japan") { return "🇯🇵" }
    if lower.contains("seoul") || lower.contains("🇰🇷") || lower.contains("korea") { return "🇰🇷" }
    if lower.contains("london") || lower.contains("🇬🇧") || lower.contains("uk") { return "🇬🇧" }
    if lower.contains("frankfurt") || lower.contains("🇩🇪") || lower.contains("germany") { return "🇩🇪" }
    if lower.contains("los angeles") || lower.contains("🇺🇸") || lower.contains("us") { return "🇺🇸" }
    if proxy.kind == .direct { return "⚡" }
    return "🌐"
}

private func timeOnly(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: date)
}

private func relativeTimestamp(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s/60)m" }
    return "\(s/3600)h"
}
