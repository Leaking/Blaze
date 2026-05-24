import NetworkExtension
import os.log
import Leaf
import HevSocks5Tunnel

// Bare-bones provider that proves the build links both native xcframeworks.
// Real implementation will reuse Sources/BlazeTunnelExtension/{PacketTunnelEngine,
// DNSProxy, UDPForwarder,...}.swift in Phase 3 once those are gated for iOS.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: "com.chenhuazhao.blaze.ios.tunnel", category: "Provider")

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // Touch both native libs once so the linker pulls in their archives
        // and we know at link time (not runtime) whether the xcframeworks
        // wired up correctly. Neither call has side effects when nothing is
        // running yet — leaf_shutdown on a non-existent rt_id returns false,
        // hev_socks5_tunnel_quit on a stopped tunnel is a no-op.
        _ = leaf_shutdown(0)
        hev_socks5_tunnel_quit()
        logger.info("startTunnel — hello-world build, no-op")
        completionHandler(nil)
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("stopTunnel reason=\(reason.rawValue, privacy: .public)")
        completionHandler()
    }
}
