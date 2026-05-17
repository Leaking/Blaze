import AppKit
import Darwin
import SwiftUI

@main
struct BlazeApp: App {
    @NSApplicationDelegateAdaptor(BlazeAppDelegate.self) private var appDelegate
    @StateObject private var store = WorkbenchStore()

    init() {
        _ = signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        WindowGroup("blaze") {
            ContentView()
                .environmentObject(store)
                .tint(.indigo)
                .frame(minWidth: 1080, minHeight: 720)
                .onOpenURL { url in
                    store.handleAutomationURL(url)
                }
                .task {
                    appDelegate.store = store
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
            CommandMenu("Proxy") {
                Button("Start Local Listeners") {
                    Task { await store.startLocalProxyStack() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Stop Local Listeners") {
                    Task {
                        await store.stopLocalProxyServer()
                        await store.stopLocalSocksServer()
                    }
                }
                .disabled(!store.localProxyRunning)

                Divider()

                Button("Start Proxy and Apply System Proxy") {
                    Task { await store.startAndApplySystemProxy() }
                }

                Button("Stop Proxy and Restore System Proxy") {
                    Task { await store.disableSystemProxyAndStop() }
                }

                Divider()

                Button("Install Packet Tunnel Extension") {
                    store.activatePacketTunnelSystemExtension()
                }

                Button("Install Packet Tunnel Config") {
                    Task { await store.installPacketTunnelConfiguration() }
                }

                Button("Start Packet Tunnel") {
                    Task { await store.startPacketTunnel() }
                }

                Button("Stop Packet Tunnel") {
                    Task { await store.stopPacketTunnel() }
                }
            }
        }

        MenuBarExtra {
            VStack(alignment: .leading) {
                Text(store.browserTrafficShouldReachBlaze ? "blaze: Connected" : "blaze: Not Effective")
                Text(store.activeRoutingSummary)
                Text("HTTP \(store.proxyListenPort) / SOCKS5 \(store.socksListenPort)")
            }

            Divider()

            Button("Open blaze") {
                BlazeApp.showMainWindow()
            }

            Button("Connect") {
                Task { await store.startAndApplySystemProxy() }
            }
            .disabled(store.browserTrafficShouldReachBlaze)

            Button("Start Local Listeners") {
                Task { await store.startLocalProxyStack() }
            }
            .disabled(store.localProxyRunning)

            Button("Disconnect") {
                Task { await store.disableSystemProxyAndStop() }
            }
            .disabled(!store.localProxyRunning && !store.effectiveProxyStatus.anyProxyEnabled)

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

            Button("Quit blaze") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Label("blaze", systemImage: store.effectiveSystemProxyIsBlaze ? "triangle.inset.filled" : "network")
        }
    }

    private static func showMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        for window in NSApplication.shared.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

final class BlazeAppDelegate: NSObject, NSApplicationDelegate {
    weak var store: WorkbenchStore?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.restoreSystemProxyForTermination()
    }
}
