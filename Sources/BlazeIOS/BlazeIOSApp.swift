import SwiftUI
import ProxyWorkbenchCore

@main
struct BlazeIOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    // Render a sample LeafConfiguration to prove the shared core is wired in.
    // Once the real UI lands this disappears; for now it doubles as a
    // smoke-test of cross-platform LeafConfiguration / renderConf().
    private let sampleConf: String = {
        LeafConfiguration(
            httpPort: 19080,
            socksPort: 19081,
            dnsServers: ["1.1.1.1", "8.8.8.8"],
            boundInterface: nil,
            logLevel: "info",
            proxies: [
                .init(tag: "direct", protocolName: "direct"),
                .init(tag: "reject", protocolName: "drop")
            ],
            rules: [.final("direct")],
            defaultProxy: "direct"
        ).renderConf()
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Blaze iOS").font(.title.bold())
                    Text("ProxyWorkbenchCore linked")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text(sampleConf)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
