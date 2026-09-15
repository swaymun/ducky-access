import ApplicationServices
import AppKit
import OSLog

struct AccessibilityHint {
    let code: String
    let frame: CGRect // AX global coordinates, never screen-local.
    let element: AXUIElement
    let label: String
}

/// UI state is main-thread owned; all cross-process AX calls run on `worker`.
final class AccessibilityNavigator {
    private(set) var active = false
    private(set) var prefix = ""
    private var snapshot: NavigationSnapshot?
    private var panels: [NSPanel] = []
    private var refreshTimer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var refreshWork: DispatchWorkItem?
    private let worker = DispatchQueue(label: "ducky.navigation.accessibility", qos: .userInitiated)
    private let lifetime = NavigationLifetime()
    private var scanSchedule = NavigationScanSchedule()
    private var activating = false
    private var electronOptIn = NavigationElectronOptIn() // Worker-owned.
    var onError: ((String) -> Void)?
    private let logger = Logger(subsystem: "com.swaymun.ducky-access", category: "navigation")

    func toggle() { active ? close() : show() }

    func backspace() {
        guard active, !prefix.isEmpty else { return }
        prefix.removeLast(); updatePrefix()
    }

    func handle(_ letter: Character) {
        guard active, !activating, let snapshot else { return }
        guard snapshot.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else { invalidate(); return }
        prefix.append(letter)
        if let hint = snapshot.hints.first(where: { $0.code == prefix }) { activate(hint, in: snapshot) }
        else if !snapshot.hints.contains(where: { $0.code.hasPrefix(prefix) }) { NSSound.beep(); prefix = "" }
        updatePrefix()
    }

    func scroll(_ amount: Int) {
        let target = active ? snapshot : nil
        if active, target == nil || target?.pid != NSWorkspace.shared.frontmostApplication?.processIdentifier { invalidate(); return }
        invalidate()
        guard let source = CGEventSource(stateID: .privateState),
              let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: Int32(amount), wheel2: 0, wheel3: 0) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: KeyboardOutput.eventTag)
        if let target {
            event.location = CGPoint(x: target.frame.midX, y: target.frame.midY)
            event.postToPid(target.pid)
        } else { event.post(tap: .cghidEventTap) }
    }

    /// Called only for unmatched events: pad hint letters never invalidate themselves.
    func inputChanged(_ type: CGEventType) {
        if [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel].contains(type) { invalidate() }
    }

    func close() {
        active = false; activating = false
        lifetime.invalidate(); scanSchedule.cancelPending()
        refreshWork?.cancel(); refreshWork = nil
        refreshTimer?.invalidate(); refreshTimer = nil
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        workspaceObserver = nil; screenObserver = nil
        clearHints()
    }

    private func show() {
        guard AXIsProcessTrusted() else {
            onError?("Enable Ducky Access in Privacy & Security → Accessibility, then relaunch."); return
        }
        active = true
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.invalidate() }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.invalidate() }
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self, !self.activating else { return }
            self.scan(fallback: true) // A busy fallback tick is dropped, never queued.
        }
        refreshTimer = timer; RunLoop.main.add(timer, forMode: .common)
        scan()
    }

    private func invalidate() {
        guard active else { return }
        lifetime.invalidate() // Cancel old work before another hint can be selected.
        activating = false; clearHints()
        // Coalesce, but do not push the deadline back on every scroll/key event.
        guard refreshWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.refreshWork = nil; self?.scan() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func scan(fallback: Bool = false) {
        guard active, !activating else { return }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { close(); return }
        let pid = app.processIdentifier
        let screens = NSScreen.screens.map(\.frame)
        guard let primary = screens.first else { return }
        let visibleScreens = screens.map { NavigationGeometry.axRect(fromAppKit: $0, primaryTop: primary.maxY) }
        let isElectron = app.bundleURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) } ?? false
        let launchDate = app.launchDate ?? .distantPast
        let ticket = lifetime.current
        guard scanSchedule.begin(fallback: fallback) else { return }
        worker.async { [weak self] in
            guard let self else { return }
            let start = ProcessInfo.processInfo.systemUptime
            if isElectron, ticket.active, self.electronOptIn.shouldAttempt(pid: pid, launchDate: launchDate) {
                let root = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(root, 0.08)
                // Electron's documented AT opt-in. Do not toggle
                // AXEnhancedUserInterface, which can affect other AT clients.
                if AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success { self.electronOptIn.succeeded(pid: pid) }
            }
            let result = NavigationScanner.scan(pid: pid, screens: visibleScreens, ticket: ticket)
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
            DispatchQueue.main.async {
                let refreshPending = self.scanSchedule.finish()
                guard self.active else { return }
                if self.lifetime.accepts(ticket), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, !self.activating {
                    if let result {
                        let changed = self.snapshot.map { !$0.matches(result) } ?? true
                        self.snapshot = result
                        if changed {
                            self.prefix = ""
                            self.render(result, screens: screens, primaryTop: primary.maxY)
                            self.logger.info("NAV snapshot pid=\(pid) hints=\(result.hints.count) nodes=\(result.visited) ms=\(elapsed) limited=\(result.limited) displays=\(self.panels.count)")
                        }
                    } else { self.clearHints() }
                }
                if refreshPending { self.scan() }
            }
        }
    }

    private func clearHints() {
        prefix = ""; snapshot = nil
        panels.forEach { $0.orderOut(nil) }; panels.removeAll()
    }

    private func render(_ snapshot: NavigationSnapshot, screens: [CGRect], primaryTop: CGFloat) {
        panels.forEach { $0.orderOut(nil) }; panels.removeAll()
        for screen in screens {
            let labels = snapshot.hints.compactMap { hint -> HintOverlayView.Label? in
                guard let frame = NavigationGeometry.localRect(hint.frame, screen: screen, primaryTop: primaryTop) else { return nil }
                return .init(code: hint.code, frame: frame)
            }
            guard !labels.isEmpty else { continue }
            let view = HintOverlayView(frame: CGRect(origin: .zero, size: screen.size)); view.labels = labels
            let panel = NSPanel(contentRect: screen, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Ducky navigation hints"
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.level = .statusBar; panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = view; panel.orderFrontRegardless(); panels.append(panel)
        }
    }

    private func updatePrefix() {
        for panel in panels {
            guard let view = panel.contentView as? HintOverlayView else { continue }
            view.prefix = prefix; view.needsDisplay = true
        }
    }

    private func activate(_ hint: AccessibilityHint, in snapshot: NavigationSnapshot) {
        activating = true
        panels.forEach { $0.orderOut(nil) } // Do not let our overlay intercept AX hit-testing.
        let ticket = lifetime.current
        worker.async { [weak self] in
            guard let self else { return }
            let valid = NavigationScanner.isCurrent(snapshot, hint: hint, ticket: ticket)
            let role = valid ? (NavigationScanner.attribute(hint.element, kAXRoleAttribute) as? String ?? "") : ""
            let press = NavigationActivation.usesPress(role: role)
            let point = NavigationActivation.clickPoint(frame: hint.frame, screens: snapshot.screens)
            let foreground = DispatchQueue.main.sync { self.active && self.lifetime.accepts(ticket) && NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid }
            var result: AXError = .invalidUIElement
            var hit = false
            if valid, foreground {
                let validateContext = {
                    let app = AXUIElementCreateApplication(snapshot.pid)
                    guard NavigationScanner.attribute(app, kAXFrontmostAttribute) as? Bool == true,
                          let focused = NavigationScanner.axElement(NavigationScanner.attribute(app, kAXFocusedWindowAttribute)),
                          CFEqual(focused, snapshot.window), NavigationScanner.read(focused)?.frame == snapshot.frame else { return false }
                    return true
                }
                if press, validateContext() {
                    AXUIElementSetMessagingTimeout(hint.element, 0.15)
                    result = ticket.performIfActive { AXUIElementPerformAction(hint.element, kAXPressAction as CFString) } ?? .invalidUIElement
                } else if !press, CGPreflightPostEventAccess(), let point, let events = NavigationActivation.clickEvents(at: point) {
                    // PID-targeted delivery cannot click another app if focus
                    // changes immediately after the final check. Always pair up.
                    let sent = NavigationActivation.dispatchClick(events: events, ticket: ticket, validateContext: validateContext, validateHit: {
                        hit = NavigationActivation.hitTest(point, hint: hint, pid: snapshot.pid, ticket: ticket)
                        return hit
                    }, post: { $0.postToPid(snapshot.pid) })
                    result = sent ? .success : .invalidUIElement // Dispatched, not proof of the app's response.
                }
            }
            DispatchQueue.main.async {
                guard self.active, self.lifetime.accepts(ticket) else { return }
                self.activating = false
                self.logger.info("NAV dispatch code=\(hint.code, privacy: .public) role=\(role, privacy: .public) method=\(press ? "AXPress" : "click", privacy: .public) result=\(result.rawValue) fresh=\(valid) hit=\(hit) foreground=\(foreground)")
                if result == .success { self.close() }
                else { self.invalidate(); self.onError?("The target changed or could not be activated. NAV refreshed; choose its new label.") }
            }
        }
    }
}

final class HintOverlayView: NSView {
    struct Label { let code: String; let frame: CGRect }
    var labels: [Label] = []
    var prefix = ""
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); dirtyRect.fill()
        for label in labels where label.code.hasPrefix(prefix) {
            let labelRect = NavigationGeometry.labelRect(for: label.frame, in: bounds)
            NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.22, alpha: 0.94).setFill()
            NSBezierPath(roundedRect: labelRect, xRadius: 5, yRadius: 5).fill()
            let text = NSAttributedString(string: label.code, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.white])
            text.draw(at: CGPoint(x: labelRect.minX + 5, y: labelRect.minY + 3))
        }
    }
}
