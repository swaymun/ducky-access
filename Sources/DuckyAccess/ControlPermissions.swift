import AppKit
import ApplicationServices

struct ControlPermissions: Equatable {
    let accessibility: Bool
    let keyboardOutput: Bool
    let inputMonitoring: Bool

    static func read() -> Self {
        Self(accessibility: AXIsProcessTrusted(), keyboardOutput: CGPreflightPostEventAccess(),
             inputMonitoring: CGPreflightListenEventAccess())
    }

    var needsRepair: Bool { !accessibility || !keyboardOutput }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
