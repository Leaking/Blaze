import Foundation
import Security
import SystemExtensions

@MainActor
final class SystemExtensionController: NSObject, OSSystemExtensionRequestDelegate {
    nonisolated static let requiredHostEntitlement = "com.apple.developer.system-extension.install"
    nonisolated static let extensionIdentifier = "com.chenhuazhao.blaze.tunnel"

    var statusHandler: ((String) -> Void)?

    nonisolated static func hostHasInstallEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault),
              let value = SecTaskCopyValueForEntitlement(task, requiredHostEntitlement as CFString, nil)
        else {
            return false
        }
        return (value as? Bool) == true
    }

    nonisolated static var hostEntitlementStatusText: String {
        hostHasInstallEntitlement() ? "Present" : "Missing in current app signature"
    }

    func activate() {
        guard Self.hostHasInstallEntitlement() else {
            statusHandler?("System extension install entitlement missing in current app signature")
            return
        }
        statusHandler?("Submitting system extension activation...")
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func deactivate() {
        guard Self.hostHasInstallEntitlement() else {
            statusHandler?("System extension install entitlement missing in current app signature")
            return
        }
        statusHandler?("Submitting system extension deactivation...")
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            statusHandler?("System extension needs approval in System Settings")
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor in
            statusHandler?("System extension request finished: \(result.rawValue)")
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            statusHandler?("System extension request failed: \(error)")
        }
    }
}
