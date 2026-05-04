import AppKit
import Darwin
import SwiftUI

@main
struct ProxyWorkbenchApp: App {
    @StateObject private var store = WorkbenchStore()

    init() {
        _ = signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        WindowGroup("Aether Proxy") {
            ContentView()
                .environmentObject(store)
                .tint(.indigo)
                .frame(minWidth: 1080, minHeight: 720)
                .task {
                    store.loadInitialProfile()
                }
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Load Sample") {
                    store.loadSample()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            VStack(alignment: .leading) {
                Text(store.localProxyRunning ? "Aether Proxy: Connected" : "Aether Proxy: Disconnected")
                Text(store.activeRoutingSummary)
                Text("HTTP \(store.proxyListenPort) / SOCKS5 \(store.socksListenPort)")
            }

            Divider()

            Button("Open Aether Proxy") {
                ProxyWorkbenchApp.showMainWindow()
            }

            Button("Connect") {
                Task { await store.startAndApplySystemProxy() }
            }
            .disabled(store.localProxyRunning)

            Button("Disconnect") {
                Task { await store.disableSystemProxyAndStop() }
            }
            .disabled(!store.localProxyRunning)

            Divider()

            Menu("Quick Switch") {
                Button("Auto Select") {
                    store.setProxyRoutingMode(.ruleBased)
                }
                ForEach(Array(store.availableGlobalPolicies.prefix(8)), id: \.self) { policy in
                    Button(policy) {
                        store.setProxyRoutingMode(.global)
                        store.setGlobalProxyPolicy(policy)
                    }
                }
            }

            Button("Import URL and Rule Sets") {
                Task { await store.importRemoteProfileAndRuleSets() }
            }
            .disabled(store.remoteProfileURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.remoteImportInProgress)

            Button("Probe Endpoints") {
                Task { await store.runLatencyChecks() }
            }
            .disabled(store.profile.proxies.isEmpty)

            Divider()

            Button("Quit Aether Proxy") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Label("Aether Proxy", systemImage: store.localProxyRunning ? "triangle.inset.filled" : "network")
        }
    }

    private static func showMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        for window in NSApplication.shared.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
