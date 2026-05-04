import AppKit
import SwiftUI

@main
struct ProxyWorkbenchApp: App {
    @StateObject private var store = WorkbenchStore()

    var body: some Scene {
        WindowGroup("Proxy Workbench") {
            ContentView()
                .environmentObject(store)
                .tint(.teal)
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
                Text(store.localProxyRunning ? "Proxy Workbench: Running" : "Proxy Workbench: Stopped")
                Text(store.activeRoutingSummary)
                Text("HTTP \(store.proxyListenPort) / SOCKS5 \(store.socksListenPort)")
            }

            Divider()

            Button("Open Proxy Workbench") {
                ProxyWorkbenchApp.showMainWindow()
            }

            Button("Start Local Listeners") {
                Task { await store.startLocalProxyStack() }
            }
            .disabled(store.localProxyRunning)

            Button("Stop Local Listeners") {
                Task { await store.stopLocalProxyStack() }
            }
            .disabled(!store.localProxyRunning)

            Divider()

            Button("Import URL and Rule Sets") {
                Task { await store.importRemoteProfileAndRuleSets() }
            }
            .disabled(store.remoteProfileURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.remoteImportInProgress)

            Button("Probe Endpoints") {
                Task { await store.runLatencyChecks() }
            }
            .disabled(store.profile.proxies.isEmpty)

            Divider()

            Button("Quit Proxy Workbench") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Label("Proxy Workbench", systemImage: store.localProxyRunning ? "bolt.horizontal.circle.fill" : "network")
        }
    }

    private static func showMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        for window in NSApplication.shared.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
