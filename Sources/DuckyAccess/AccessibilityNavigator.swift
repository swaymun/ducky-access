import ApplicationServices
import AppKit
import OSLog

struct AccessibilityHint {
    let code: String
    let frame: CGRect
    let element: AXUIElement
    let label: String
}

final class AccessibilityNavigator {
    private let alphabet = Array("ABCDEFGHIJKLMNO")
    private(set) var active = false
    private(set) var prefix = ""
    private var hints: [AccessibilityHint] = []
    private var window: NSPanel?
    private var overlay: HintOverlayView?
    var onError: ((String) -> Void)?
    private let logger = Logger(subsystem: "com.swaymun.ducky-access", category: "navigation")

    func toggle() {
        active ? close() : show()
    }

    func backspace() {
        guard active else { return }
        guard !prefix.isEmpty else { return }
        prefix.removeLast()
        overlay?.prefix = prefix
        overlay?.needsDisplay = true
    }

    func handle(_ letter: Character) {
        guard active else { return }
        prefix.append(letter)
        if let hint = hints.first(where: { $0.code == prefix }) {
            activate(hint)
            close()
        } else if !hints.contains(where: { $0.code.hasPrefix(prefix) }) {
            NSSound.beep()
            prefix = ""
        }
        overlay?.prefix = prefix
        overlay?.needsDisplay = true
    }

    func scroll(_ amount: Int) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: Int32(amount), wheel2: 0, wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }

    func close() {
        active = false
        prefix = ""
        window?.orderOut(nil)
        window = nil
        overlay = nil
        hints.removeAll()
    }

    private func show() {
        guard AXIsProcessTrusted() else {
            logger.error("NAV blocked: Accessibility permission is not valid for this build")
            onError?("Re-add /Applications/DuckyAccess.app in Privacy & Security → Accessibility, enable it, then relaunch.")
            NSSound.beep()
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        hints = collect(from: axApp)
        logger.info("NAV collected hints=\(self.hints.count) destinationPID=\(app.processIdentifier)")
        guard !hints.isEmpty else { onError?("No accessible controls found in the current app."); return }
        active = true
        prefix = ""
        let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let view = HintOverlayView(frame: CGRect(origin: .zero, size: screen.size))
        view.hints = hints
        view.onEscape = { [weak self] in self?.close() }
        let panel = NSPanel(contentRect: screen, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view
        panel.orderFrontRegardless()
        window = panel
        overlay = view
    }

    private func collect(from root: AXUIElement) -> [AccessibilityHint] {
        var elements: [(AXUIElement, CGRect, String)] = []
        var windowsValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windowsValue) == .success,
           let windows = windowsValue as? [AXUIElement] {
            for item in windows { walk(item, into: &elements) }
        } else {
            walk(root, into: &elements)
        }
        let unique = elements.filter { item in
            item.1.width > 4 && item.1.height > 4
        }.prefix(225)
        return unique.enumerated().map { index, item in
            let code = String(alphabet[index / 15]) + String(alphabet[index % 15])
            return AccessibilityHint(code: code, frame: convert(item.1), element: item.0, label: item.2)
        }
    }

    private func walk(_ element: AXUIElement, into result: inout [(AXUIElement, CGRect, String)]) {
        var roleValue: CFTypeRef?
        var titleValue: CFTypeRef?
        var descValue: CFTypeRef?
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        _ = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)
        _ = AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descValue)
        _ = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
        _ = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        let role = roleValue as? String ?? ""
        let actionableRoles: Set<String> = [
            "AXButton", "AXLink", "AXMenuItem", "AXTextField", "AXTextArea",
            "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox",
            "AXSlider", "AXTabGroup", "AXCell"
        ]
        if actionableRoles.contains(role), let frame = rect(position: positionValue, size: sizeValue) {
            let title = (titleValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let desc = (descValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            result.append((element, frame, title.isEmpty ? desc : title))
        }
        var childrenValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
           let children = childrenValue as? [AXUIElement] {
            for child in children { walk(child, into: &result) }
        }
    }

    private func rect(position: CFTypeRef?, size: CFTypeRef?) -> CGRect? {
        guard let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }

    private func convert(_ rect: CGRect) -> CGRect {
        let screen = NSScreen.main?.frame ?? .zero
        return CGRect(x: rect.minX, y: screen.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func activate(_ hint: AccessibilityHint) {
        var roleValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(hint.element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""
        let result: AXError
        if role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" {
            result = AXUIElementSetAttributeValue(hint.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        } else {
            result = AXUIElementPerformAction(hint.element, kAXPressAction as CFString)
        }
        logger.info("NAV activate role=\(role, privacy: .public) result=\(result.rawValue)")
        if result != .success { NSSound.beep() }
    }
}

final class HintOverlayView: NSView {
    var hints: [AccessibilityHint] = []
    var prefix = ""
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); dirtyRect.fill()
        for hint in hints {
            let rect = hint.frame.insetBy(dx: 1, dy: 1)
            let labelRect = CGRect(x: rect.minX, y: rect.maxY - 21, width: max(24, CGFloat(hint.code.count * 10 + 10)), height: 20)
            NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.22, alpha: 0.94).setFill()
            NSBezierPath(roundedRect: labelRect, xRadius: 5, yRadius: 5).fill()
            let text = NSAttributedString(string: hint.code, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.white])
            text.draw(at: CGPoint(x: labelRect.minX + 5, y: labelRect.minY + 3))
        }
        if !prefix.isEmpty {
            let text = NSAttributedString(string: prefix, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 18, weight: .bold), .foregroundColor: NSColor.white])
            let size = text.size()
            let box = CGRect(x: bounds.midX - size.width / 2 - 12, y: bounds.maxY - 70, width: size.width + 24, height: size.height + 14)
            NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.22, alpha: 0.94).setFill()
            NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
            text.draw(at: CGPoint(x: box.minX + 12, y: box.minY + 7))
        }
    }
}
