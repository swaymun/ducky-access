import AppKit

/// Explicit local-only delivery fixture (--nav-click-probe). It does not start
/// the bridge or send input to other apps. A human/UI test must press Run.
final class NavigationClickProbe: NSObject, NSWindowDelegate {
    private var window: NSWindow!
    private let received = NSTextField(labelWithString: "Received: 0")
    private let result = NSTextField(labelWithString: "Not run")
    private var target: NSButton!
    private var runButton: NSButton!
    private var count = 0

    func show() {
        window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 560, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Ducky NAV click delivery test"
        window.delegate = self
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        target = NSButton(title: "Test target — counts clicks", target: self, action: #selector(clicked))
        target.frame = CGRect(x: 32, y: 175, width: 270, height: 38)
        received.frame = CGRect(x: 330, y: 183, width: 180, height: 24)
        runButton = NSButton(title: "Run delivery comparison", target: self, action: #selector(run))
        runButton.frame = CGRect(x: 32, y: 110, width: 270, height: 38)
        result.frame = CGRect(x: 32, y: 20, width: 500, height: 75)
        result.maximumNumberOfLines = 3
        [target!, received, runButton!, result].forEach(content.addSubview)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func clicked() { count += 1; received.stringValue = "Received: \(count)" }

    @objc private func run() {
        guard window.isKeyWindow, let primary = NSScreen.screens.first else { return }
        runButton.isEnabled = false; count = 0; received.stringValue = "Received: 0"
        result.stringValue = "Testing old unaddressed events…"
        let global = window.convertPoint(toScreen: CGPoint(x: target.frame.midX, y: target.frame.midY))
        let point = CGPoint(x: global.x, y: primary.frame.maxY - global.y)
        let frame = NavigationGeometry.axRect(fromAppKit: window.frame, primaryTop: primary.frame.maxY)
        let pid = ProcessInfo.processInfo.processIdentifier
        guard NavigationActivation.destinationWindow(at: point, primaryTop: primary.frame.maxY, pid: pid, frame: frame) == window.windowNumber else { finish("FAIL: destination-window check"); return }
        let source = CGEventSource(stateID: .privateState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { finish("FAIL: event construction"); return }
            event.flags = []; event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.postToPid(pid)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            let old = count; count = 0; received.stringValue = "Received: 0"
            guard window.isKeyWindow, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let events = NavigationActivation.clickEvents(at: point, windowNumber: window.windowNumber) else { finish("Cancelled: test lost focus"); return }
            result.stringValue = "Testing window-addressed events…"
            for event in events { event.postToPid(pid) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                finish("Old delivery: \(old) click(s)\nWindow-addressed delivery: \(count) click(s)\n\(count == 1 ? "PASS" : "FAIL") — expected exactly one addressed click")
            }
        }
    }

    private func finish(_ text: String) { result.stringValue = text; runButton.isEnabled = true }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}
