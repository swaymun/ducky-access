import AppKit
import ApplicationServices

protocol ShortcutExecuting: AnyObject {
    func run(_ plan: ShortcutPlan, initialPID: pid_t?, progress: @escaping (String) -> Void,
             completion: @escaping (Result<String, Error>) -> Void)
    func cancel()
}

/// Executes a validated catalog, never model-generated keycodes. No screen
/// capture/tree walk/model round trips: only local window/focus/field checks.
final class ShortcutExecutor: ShortcutExecuting {
    private let gate = NativeComputerControl.CancellationGate()
    private let worker = DispatchQueue(label: "ducky.shortcuts.accessibility", qos: .userInitiated)
    private var expectedPID: pid_t?
    private var completion: ((Result<String, Error>) -> Void)?
    private var progress: ((String) -> Void)?
    private var steps: [ShortcutPlan.Step] = []
    private var index = 0
    // Worker-owned window guard; a planned new-window action resets it.
    private var windows: [pid_t: AXUIElement] = [:]

    func run(_ plan: ShortcutPlan, initialPID: pid_t?, progress: @escaping (String) -> Void,
             completion: @escaping (Result<String, Error>) -> Void) {
        guard gate.active else { return }
        self.completion = completion; self.progress = progress; steps = plan.steps; expectedPID = initialPID
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            finish(.failure(ShortcutPlan.Fault("Enable Ducky Access Accessibility permission."))); return
        }
        next()
    }

    func cancel() { gate.cancel(); completion = nil; progress = nil }

    private func next() {
        guard gate.active else { return }
        guard index < steps.count else {
            finish(.success("Sent \(steps.count) shortcut action\(steps.count == 1 ? "" : "s").")); return
        }
        guard expectedPID == NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            fail("App focus changed."); return
        }
        let step = steps[index]
        guard let action = ShortcutPlan.action(step.action) else { fail("Unknown shortcut."); return }
        progress?("Shortcuts \(index + 1)/\(steps.count) · \(action.title)")
        guard gate.active else { return }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: action.app).first {
            activate(app, step: step, action: action)
        } else {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: action.app) else { fail("\(action.app) is not installed."); return }
            let config = NSWorkspace.OpenConfiguration(); config.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] app, error in
                DispatchQueue.main.async {
                    guard let self, self.gate.active else { return }
                    guard self.expectedPID == NSWorkspace.shared.frontmostApplication?.processIdentifier else { self.fail("App focus changed while launching."); return }
                    guard let app else { self.fail(error?.localizedDescription ?? "App did not launch."); return }
                    self.activate(app, step: step, action: action)
                }
            }
        }
    }

    private func activate(_ app: NSRunningApplication, step: ShortcutPlan.Step, action: ShortcutPlan.Action) {
        guard gate.active else { return }
        app.activate(options: [.activateAllWindows])
        expectedPID = app.processIdentifier
        awaitFocus(app.processIdentifier, step: step, action: action, attempts: 20)
    }

    private func awaitFocus(_ pid: pid_t, step: ShortcutPlan.Step, action: ShortcutPlan.Action, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.gate.active else { return }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                if attempts > 0 { self.awaitFocus(pid, step: step, action: action, attempts: attempts - 1) }
                else { self.fail("Could not focus the target app.") }
                return
            }
            if action.id.hasSuffix(".focus") { self.advance(); return }
            self.worker.async {
                do {
                    try self.checkWindow(pid, allowNew: action.id == "chrome.new_window")
                    if action.takesArgument {
                        try self.send(action.id == "chrome.navigate" ? "Command L" : "Command F", pid: pid)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                            guard let self, self.gate.active else { return }
                            self.fill(step, pid: pid)
                        }
                    } else if let chord = action.chord {
                        try self.send(chord, pid: pid)
                        if action.id == "chrome.new_window" { self.windows.removeValue(forKey: pid) }
                        DispatchQueue.main.async { self.advance() }
                    }
                } catch { DispatchQueue.main.async { self.fail(error.localizedDescription) } }
            }
        }
    }

    private func fill(_ step: ShortcutPlan.Step, pid: pid_t) {
        worker.async {
            do {
                try self.checkWindow(pid)
                let root = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(root, 0.2)
                guard let field = self.element(root, kAXFocusedUIElementAttribute),
                      self.attribute(field, kAXRoleAttribute) as? String == "AXTextField",
                      self.attribute(field, kAXSubroleAttribute) as? String != "AXSecureTextField" else {
                    throw ShortcutPlan.Fault("Expected Chrome's non-password toolbar text field.")
                }
                let description = [kAXDescriptionAttribute, kAXTitleAttribute, "AXIdentifier", kAXHelpAttribute]
                    .compactMap { self.attribute(field, $0) as? String }.joined(separator: " ").lowercased()
                let validField = step.action == "chrome.navigate"
                    ? description.contains("address") || description.contains("omnibox")
                    : description.contains("find")
                guard validField else { throw ShortcutPlan.Fault("Chrome's expected address/find field was not focused.") }
                let text = step.argument!
                try self.checkFocus(pid)
                let error = try self.gate.dispatch { AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString) }
                guard error == .success else { throw ShortcutPlan.Fault("Chrome did not accept the toolbar text.") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self, self.gate.active else { return }
                    self.worker.async {
                        do {
                            try self.checkWindow(pid)
                            guard let now = self.element(root, kAXFocusedUIElementAttribute), CFEqual(field, now),
                                  self.attribute(field, kAXValueAttribute) as? String == text else {
                                throw ShortcutPlan.Fault("Toolbar focus or text changed; Return was not sent.")
                            }
                            if step.action == "chrome.navigate" { try self.send("Enter", pid: pid) }
                            DispatchQueue.main.async { self.advance() }
                        } catch { DispatchQueue.main.async { self.fail(error.localizedDescription) } }
                    }
                }
            } catch { DispatchQueue.main.async { self.fail(error.localizedDescription) } }
        }
    }

    private func advance() {
        guard gate.active else { return }
        index += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.next() }
    }

    private func send(_ chord: String, pid: pid_t) throws {
        guard let shortcut = NativeComputerControl.shortcut(chord) else { throw ShortcutPlan.Fault("Unsupported shortcut binding.") }
        try DispatchQueue.main.sync {
            guard gate.active, expectedPID == pid, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                throw ShortcutPlan.Fault("Cancelled or app focus changed.")
            }
            guard KeyboardOutput.send(shortcut, to: pid) else { throw ShortcutPlan.Fault("Keyboard output failed.") }
        }
    }

    private func checkFocus(_ pid: pid_t) throws {
        guard gate.active, DispatchQueue.main.sync(execute: { NSWorkspace.shared.frontmostApplication?.processIdentifier }) == pid else {
            throw ShortcutPlan.Fault("Cancelled or app focus changed.")
        }
    }

    private func checkWindow(_ pid: pid_t, allowNew: Bool = false) throws {
        try checkFocus(pid)
        let root = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(root, 0.2)
        guard let window = element(root, kAXFocusedWindowAttribute) else {
            if allowNew { return }
            throw ShortcutPlan.Fault("No focused window. Open the app's window first.")
        }
        if let previous = windows[pid], !CFEqual(previous, window) { throw ShortcutPlan.Fault("The target window changed.") }
        guard attribute(window, kAXModalAttribute) as? Bool == false,
              (attribute(window, "AXSheets") as? [AXUIElement] ?? []).isEmpty,
              attribute(window, kAXSubroleAttribute) as? String != "AXDialog" else {
            throw ShortcutPlan.Fault("A dialog needs your attention; shortcuts stopped.")
        }
        if let focus = element(root, kAXFocusedUIElementAttribute),
           attribute(focus, kAXSubroleAttribute) as? String == "AXSecureTextField" {
            throw ShortcutPlan.Fault("Shortcuts stopped at a protected field.")
        }
        windows[pid] = window
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        guard gate.active else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.2)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }
    private func element(_ root: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = attribute(root, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func fail(_ message: String) {
        finish(.failure(ShortcutPlan.Fault("\(message) Stopped after \(index) completed shortcut actions; the current action may be partial. Check the app before retrying. Nothing was replayed.")))
    }
    private func finish(_ result: Result<String, Error>) {
        guard gate.active else { return }
        let callback = completion
        cancel(); callback?(result)
    }
}
