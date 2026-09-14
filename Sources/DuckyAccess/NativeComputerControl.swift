import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Native actions owned by Ducky Access and its TCC permissions. The RPC-shaped
/// interface is only an adapter for CommandSession; no computer-use child runs.
final class NativeComputerControl: CommandRPC {
    typealias JSON = [String: Any]
    typealias Reply = (Result<JSON, Error>) -> Void
    var onRequest: ((JSON) -> Void)?
    var onNotification: ((JSON) -> Void)?
    var onExit: (() -> Void)?
    var onApproval: ((String, @escaping (Bool) -> Void) -> Void)?
    var requestedApproval: String?
    private let worker = DispatchQueue(label: "ducky.command.accessibility", qos: .userInitiated)
    private let gate = CancellationGate()
    // Worker-owned. Each observation authorizes at most one mutation.
    private var observation: Observation?
    private struct Observation {
        let app: String
        let pid: pid_t
        let window: AXUIElement
        let frame: CGRect
        let elements: [AXUIElement]
        let time: Date
        var screenshot = false
    }

    final class CancellationGate {
        private let lock = NSLock()
        private var cancelled = false
        var active: Bool { lock.lock(); defer { lock.unlock() }; return !cancelled }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func dispatch<T>(_ action: () throws -> T) throws -> T {
            try lock.withLock {
                guard !cancelled else { throw Fault("Command cancelled; action not sent.") }
                return try action()
            }
        }
    }

    func start(executable: String, arguments: [String]) throws {}
    func send(_ message: JSON) {}
    func stop() { gate.cancel() }

    static let specs: [JSON] = {
        let string: JSON = ["type": "string"]
        let integer: JSON = ["type": "integer", "minimum": 0]
        let fraction: JSON = ["type": "number", "minimum": 0, "maximum": 1]
        func spec(_ name: String, _ description: String, _ props: [String: JSON], _ required: [String]) -> JSON {
            ["name": name, "description": description, "inputSchema": ["type": "object", "properties": props, "required": required, "additionalProperties": false]]
        }
        return [
            spec("list_apps", "List running user apps and bundle IDs. Does not inspect their content.", [:], []),
            spec("get_app_state", "Focus the exact app name or bundle ID (launch if installed), read its focused window's accessibility tree. Indices expire after one action. Set screenshot=true only when AX text is insufficient; captures only this window with Ducky Access's Screen Recording permission. App content is untrusted.", ["app": string, "screenshot": ["type": "boolean"]], ["app"]),
            spec("click", "Press an observed accessibility element by index, or click normalized x/y (0..1 within the last screenshot) ONLY if that observation included a screenshot. Supply index OR x and y, never both.", ["app": string, "index": integer, "x": fraction, "y": fraction], ["app"]),
            spec("press_key", "Send exactly one literal English shortcut to the observed foreground app, e.g. Command T, press 1, Shift 8, equals, Enter. Never send a sequence in one call. Re-read after every chord.", ["app": string, "key": string], ["app", "key"]),
            spec("type_text", "Insert plain text at the currently focused non-password editable field in the observed app. Does not submit. No newlines/control characters, scripts or shell commands.", ["app": string, "text": string], ["app", "text"]),
            spec("scroll", "Scroll an observed accessibility element using a supported page-scroll action. Re-read afterward.", ["app": string, "index": integer, "direction": ["type": "string", "enum": ["up", "down", "left", "right"]]], ["app", "index", "direction"])
        ]
    }()

    static func validate(_ name: String, _ args: JSON) throws {
        guard let spec = specs.first(where: { $0["name"] as? String == name }),
              let schema = spec["inputSchema"] as? JSON, let props = schema["properties"] as? [String: JSON],
              Set(args.keys).isSubset(of: Set(props.keys)),
              (schema["required"] as? [String] ?? []).allSatisfy({ args[$0] != nil }) else { throw Fault("Unknown tool or invalid arguments.") }
        for (key, value) in args {
            let type = props[key]?["type"] as? String
            if type == "string", !(value is String) { throw Fault("\(key) must be text.") }
            if type == "boolean", !(value is NSNumber) || CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() { throw Fault("\(key) must be boolean.") }
            if type == "integer" || type == "number" {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                      number.doubleValue >= 0, type != "integer" || number.doubleValue.rounded() == number.doubleValue,
                      key == "index" ? number.doubleValue < 500 : number.doubleValue <= 1 else { throw Fault("Invalid \(key).") }
            }
        }
        if name != "list_apps", (args["app"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw Fault("Specify the exact app.") }
        if name == "click" {
            guard (args["index"] != nil && args["x"] == nil && args["y"] == nil) || (args["index"] == nil && args["x"] != nil && args["y"] != nil) else { throw Fault("Use an index OR both screenshot coordinates.") }
        }
        if name == "press_key", shortcut(args["key"] as? String ?? "") == nil { throw Fault("Specify one literal shortcut, e.g. Command T.") }
        if name == "type_text" {
            let text = args["text"] as? String ?? ""
            guard !text.isEmpty, text.utf16.count <= 8000, text.rangeOfCharacter(from: .controlCharacters) == nil else { throw Fault("Text must be 1–8000 characters without newlines/control characters. Use a separate confirmed Enter action to submit.") }
        }
        if name == "scroll", !["up", "down", "left", "right"].contains(args["direction"] as? String ?? "") { throw Fault("Invalid scroll direction.") }
    }

    static func shortcut(_ key: String) -> KeyboardShortcut? {
        // The tool name already supplies the "press" intent. Unlike free-form
        // dictation, bare letters/digits here are unambiguous literal keys.
        switch SpokenShortcut.parse(key) {
        case .shortcut(let shortcut): return shortcut
        case .notShortcut:
            if case .shortcut(let shortcut) = SpokenShortcut.parse("press " + key) { return shortcut }
            return nil
        case .invalid: return nil
        }
    }

    func request(_ method: String, _ params: JSON, timeout: TimeInterval, reply: @escaping Reply) {
        guard gate.active else { return }
        if method == "initialize" { reply(.success([:])); return }
        if method == "tools/list" { reply(.success(["tools": Self.specs])); return }
        guard method == "tools/call", let name = params["name"] as? String, let args = params["arguments"] as? JSON else {
            reply(.failure(Fault("Unsupported native request."))); return
        }
        do { try Self.validate(name, args) } catch { reply(.success(Self.failure(error))); return }
        if name == "list_apps" {
            let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map { ["name": $0.localizedName ?? "", "app": $0.bundleIdentifier ?? ""] }
            reply(.success(Self.text(String(data: (try? JSONSerialization.data(withJSONObject: apps)) ?? Data(), encoding: .utf8) ?? "[]"))); return
        }
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            reply(.success(Self.failure(Fault("Ducky Access needs its own Accessibility permission."), fatal: true))); return
        }
        let app = args["app"] as! String
        // Resolve/activate on main; slow AX requests always run off-main so the
        // notch can cancel even when the target application stops responding.
        if name == "get_app_state" {
            resolve(app) { [weak self] result in
                guard let self, self.gate.active else { return }
                switch result {
                case .failure(let error): reply(.success(Self.failure(error)))
                case .success(let running):
                    self.worker.async {
                        self.observation = nil
                        self.perform(reply) { try self.snapshot(app, pid: running.processIdentifier, screenshot: args["screenshot"] as? Bool == true) }
                    }
                }
            }
        } else {
            worker.async { self.perform(reply) { try self.mutate(name, args) } }
        }
    }

    private func perform(_ reply: @escaping Reply, _ work: () throws -> JSON) {
        guard gate.active else { return }
        let result: JSON
        do { result = try work() } catch { result = Self.failure(error) }
        DispatchQueue.main.async { if self.gate.active { reply(.success(result)) } }
    }

    private func resolve(_ name: String, completion: @escaping (Result<NSRunningApplication, Error>) -> Void) {
        let matches = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == name || $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }
        guard matches.count <= 1 else { completion(.failure(Fault("Ambiguous app; use its bundle ID."))); return }
        let blocked: Set<String> = [Bundle.main.bundleIdentifier ?? "com.swaymun.ducky-access", "com.swaymun.ducky-access", "com.apple.Terminal", "com.googlecode.iterm2", "com.apple.ScriptEditor2"]
        func activate(_ app: NSRunningApplication) {
            guard gate.active else { return }
            guard !blocked.contains(app.bundleIdentifier ?? "") else { completion(.failure(Fault("This app is outside the command controller's allowed surface."))); return }
            guard app.activate(options: [.activateAllWindows]) else { completion(.failure(Fault("Could not focus the requested app."))); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { if self.gate.active { completion(.success(app)) } }
        }
        if let app = matches.first { activate(app); return }
        guard !blocked.contains(name), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) else {
            completion(.failure(Fault("App is not running. Use the installed application's exact bundle ID to open it."))); return
        }
        let config = NSWorkspace.OpenConfiguration(); config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            DispatchQueue.main.async {
                guard self.gate.active else { return }
                if let app { activate(app) } else { completion(.failure(error ?? Fault("Could not open app."))) }
            }
        }
    }

    private func snapshot(_ name: String, pid: pid_t, screenshot: Bool) throws -> JSON {
        try checkActive(pid)
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.3)
        guard let window = elementAttribute(root, kAXFocusedWindowAttribute), let frame = frame(window) else { throw Fault("No focused window is available. Open a window in the requested app.") }
        let deadline = Date().addingTimeInterval(6)
        var elements: [AXUIElement] = [], lines: [String] = [], seen = Set<CFHashCode>(), size = 0, protectedContent = false, complete = true
        func visit(_ element: AXUIElement, _ depth: Int) {
            guard gate.active, Date() < deadline, depth < 25, elements.count < 500, size < 40000 else { complete = false; return }
            guard seen.insert(CFHash(element)).inserted else { return }
            AXUIElementSetMessagingTimeout(element, 0.3)
            let roleValue = attribute(element, kAXRoleAttribute) as? String
            if roleValue == nil { complete = false }
            let role = roleValue ?? "element"
            let index = elements.count; elements.append(element)
            let secure = isSecure(element, complete: &complete)
            protectedContent = protectedContent || secure
            let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { key -> String? in
                guard !secure, let value = attribute(element, key), !(value is [Any]) else { return nil }
                if let text = value as? String { return String(text.prefix(400)) }
                if let value = value as? NSNumber { return value.stringValue }
                return nil
            }
            let line = "[\(index)] \(role) \(secure ? "[protected field]" : labels.joined(separator: " | "))"
            lines.append(line); size += line.count
            if secure { return }
            var children: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            if error != .success && error != .attributeUnsupported && error != .noValue { complete = false }
            for child in children as? [AXUIElement] ?? [] { visit(child, depth + 1) }
        }
        visit(window, 0)
        try checkActive(pid)
        var state = Observation(app: name, pid: pid, window: window, frame: frame, elements: elements, time: Date())
        var content: [JSON] = [["type": "text", "text": "App: \(name). Current window only.\n" + lines.joined(separator: "\n") + "\n(Tree is bounded to 500 nodes/6 seconds; may be partial.)"]]
        if screenshot {
            if protectedContent || !complete {
                content.append(["type": "text", "text": "Screenshot withheld: protected field found or accessibility screening was incomplete."])
            } else if CGPreflightScreenCaptureAccess() {
                if let png = try capture(pid: pid, frame: frame) {
                    content.append(["type": "image", "mimeType": "image/png", "data": png.base64EncodedString()]); state.screenshot = true
                } else { content.append(["type": "text", "text": "Screenshot unavailable. Use AX indices; do not guess coordinates."]) }
            } else { content.append(["type": "text", "text": "Ducky Access does not have Screen Recording permission. AX navigation remains available; screenshot coordinates cannot be used."]) }
        }
        observation = state
        return ["content": content]
    }

    private func mutate(_ name: String, _ args: JSON) throws -> JSON {
        guard let state = observation, state.app == args["app"] as? String, Date().timeIntervalSince(state.time) < 30 else { throw Fault("Read fresh app state before acting (observation expired or missing).") }
        observation = nil
        let bundleID = DispatchQueue.main.sync { NSRunningApplication(processIdentifier: state.pid)?.bundleIdentifier ?? "" }
        if Self.requiresNativeConfirmation(name, bundleID: bundleID) || requestedApproval != nil {
            let detail: String
            if name == "type_text" { detail = "Insert this exact text:\n" + String((args["text"] as? String ?? "").prefix(8000)) }
            else if name == "press_key" { detail = "Press: " + (args["key"] as? String ?? "") }
            else { detail = "Perform \(name) using \(args)." }
            try confirm("App: \(bundleID)\n\(requestedApproval.map { $0 + "\n" } ?? "")\(detail)\n\nThis action may operate app features or execute commands. Allow only if you recognize the app and intended action.")
        }
        try checkActive(state.pid)
        let root = AXUIElementCreateApplication(state.pid); AXUIElementSetMessagingTimeout(root, 0.3)
        guard let current = elementAttribute(root, kAXFocusedWindowAttribute), CFEqual(current, state.window), frame(current) == state.frame else { throw Fault("The window changed. Read fresh state before acting.") }
        let focused = elementAttribute(root, kAXFocusedUIElementAttribute)
        if let focused, isSecure(focused) { throw Fault("Input into password/protected fields is not supported.") }
        switch name {
        case "press_key":
            guard let shortcut = Self.shortcut(args["key"] as! String) else { throw Fault("Invalid shortcut.") }
            try onMain(state.pid) { guard KeyboardOutput.send(shortcut, to: state.pid) else { throw Fault("Keyboard event could not be sent.") } }
        case "type_text":
            guard let focused, ["AXTextField", "AXTextArea", "AXComboBox"].contains(attribute(focused, kAXRoleAttribute) as? String ?? "") else { throw Fault("Focus a non-password editable text field before typing.") }
            let chars = Array((args["text"] as! String).utf16)
            var offset = 0
            while offset < chars.count {
                var end = min(offset + 64, chars.count)
                if end < chars.count && (0xD800...0xDBFF).contains(chars[end - 1]) { end -= 1 }
                let chunk = Array(chars[offset..<end])
                guard let now = elementAttribute(root, kAXFocusedUIElementAttribute), CFEqual(now, focused), !isSecure(now),
                      let window = elementAttribute(root, kAXFocusedWindowAttribute), CFEqual(window, state.window), frame(window) == state.frame else {
                    throw Fault("Text focus changed; remaining text was not sent. Check the partially inserted text before retrying.")
                }
                try onMain(state.pid) {
                    guard let source = CGEventSource(stateID: .privateState) else { throw Fault("Keyboard source unavailable.") }
                    for down in [true, false] {
                        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { throw Fault("Keyboard event unavailable.") }
                        event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                        event.setIntegerValueField(.eventSourceUserData, value: KeyboardOutput.eventTag)
                        event.postToPid(state.pid)
                    }
                }
                offset = end
            }
        case "click", "scroll":
            if let index = args["index"] as? Int {
                guard state.elements.indices.contains(index) else { throw Fault("Unknown element index. Read current state.") }
                let element = state.elements[index]
                guard !isSecure(element), attribute(element, kAXEnabledAttribute) as? Bool != false else { throw Fault("Element is protected or disabled.") }
                let action: String
                if name == "scroll" { action = "AXScroll\((args["direction"] as! String).capitalized)ByPage" }
                else { action = kAXPressAction }
                var supported: CFArray?
                AXUIElementCopyActionNames(element, &supported)
                try checkActive(state.pid)
                if (supported as? [String] ?? []).contains(action) {
                    guard try gate.dispatch({ AXUIElementPerformAction(element, action as CFString) }) == .success else { throw Fault("Accessibility action failed. Inspect the app before retrying.") }
                } else if name == "click", ["AXTextField", "AXTextArea", "AXComboBox"].contains(attribute(element, kAXRoleAttribute) as? String ?? "") {
                    guard try gate.dispatch({ AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) }) == .success else { throw Fault("Could not focus the field.") }
                } else { throw Fault("Element does not support this accessibility action. Request a screenshot for a coordinate click, or use an observed keyboard shortcut.") }
            } else {
                guard name == "click", state.screenshot, let x = args["x"] as? Double, let y = args["y"] as? Double else { throw Fault("Coordinate clicks require a fresh screenshot.") }
                let point = CGPoint(x: state.frame.minX + x * state.frame.width, y: state.frame.minY + y * state.frame.height)
                try onMain(state.pid) {
                    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { throw Fault("Mouse event unavailable.") }
                        event.setIntegerValueField(.eventSourceUserData, value: KeyboardOutput.eventTag)
                        event.postToPid(state.pid)
                    }
                }
            }
        default: throw Fault("Unsupported action.")
        }
        return Self.text("Action dispatched. Read get_app_state to verify the result before another action.")
    }

    private func checkActive(_ pid: pid_t) throws {
        guard gate.active else { throw Fault("Command cancelled.") }
        let front = DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard front == pid else { throw Fault("Focus changed. No further input sent; read the intended app again.") }
    }

    private func onMain(_ pid: pid_t, _ action: () throws -> Void) throws {
        try DispatchQueue.main.sync {
            guard gate.active, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw Fault("Cancelled or focus changed; input not sent.") }
            try action()
        }
    }

    // A deliberately small automatic-action surface. The model cannot opt out
    // of confirmation for unknown apps or text injection into an execution host.
    // Literal user-spoken shortcuts and ordinary DICT do not use this agent path.
    static func requiresNativeConfirmation(_ name: String, bundleID: String) -> Bool {
        if bundleID == "com.apple.calculator" { return false }
        if bundleID == "com.apple.TextEdit" { return name == "type_text" }
        return true
    }

    private func confirm(_ message: String) throws {
        let done = DispatchSemaphore(value: 0), lock = NSLock()
        var approved = false
        DispatchQueue.main.async {
            guard self.gate.active, let onApproval = self.onApproval else { done.signal(); return }
            onApproval(message) { value in lock.withLock { approved = value }; done.signal() }
        }
        let deadline = Date().addingTimeInterval(60)
        while done.wait(timeout: .now() + 0.1) == .timedOut {
            guard gate.active, Date() < deadline else { throw Fault("Command confirmation cancelled or expired.", fatal: true) }
        }
        guard gate.active, lock.withLock({ approved }) else { throw Fault("Action was not approved. Stop and ask the user.") }
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        guard gate.active else { return nil }
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        var complete = true
        let secure = isSecure(element, complete: &complete)
        return secure || !complete
    }

    private func isSecure(_ element: AXUIElement, complete: inout Bool) -> Bool {
        var secure = false
        for key in [kAXSubroleAttribute, "AXProtectedContent"] {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
            if error != .success && error != .attributeUnsupported && error != .noValue { complete = false }
            secure = secure || value as? String == "AXSecureTextField" || value as? Bool == true
        }
        return secure
    }

    private func elementAttribute(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = attribute(element, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = attribute(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func capture(pid: pid_t, frame: CGRect) throws -> Data? {
        // Only a matching foreground window is captured; never the full desktop.
        let done = DispatchSemaphore(value: 0)
        let deadline = Date().addingTimeInterval(8)
        let lock = NSLock()
        var result: Data?
        let task = Task {
            defer { done.signal() }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true), gate.active else { return }
            let matches = content.windows.filter { $0.owningApplication?.processID == pid && abs($0.frame.minX - frame.minX) < 2 && abs($0.frame.minY - frame.minY) < 2 && abs($0.frame.width - frame.width) < 2 && abs($0.frame.height - frame.height) < 2 }
            guard matches.count == 1, let window = matches.first else { return }
            let config = SCStreamConfiguration(); config.width = Int(frame.width); config.height = Int(frame.height); config.showsCursor = false
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config), gate.active else { return }
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            lock.withLock { result = png }
        }
        while done.wait(timeout: .now() + 0.1) == .timedOut {
            if !gate.active { task.cancel(); throw Fault("Command cancelled.") }
            if Date() > deadline { task.cancel(); return nil }
        }
        try checkActive(pid)
        lock.lock(); defer { lock.unlock() }; return result
    }

    private static func text(_ text: String) -> JSON { ["content": [["type": "text", "text": text]]] }
    private static func failure(_ error: Error, fatal: Bool = false) -> JSON {
        ["isError": true, "fatal": fatal || (error as? Fault)?.fatal == true, "content": [["type": "text", "text": error.localizedDescription]]]
    }
    struct Fault: LocalizedError {
        let message: String
        let fatal: Bool
        init(_ message: String, fatal: Bool = false) { self.message = message; self.fatal = fatal }
        var errorDescription: String? { message }
    }
}
