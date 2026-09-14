import AppKit
import ApplicationServices
import OSLog

/// Checks the destination and permission before posting, then checks the field
/// afterwards. Creating a CGEvent does not prove macOS delivered it.
final class TextInserter {
    struct Target {
        let pid: pid_t
        let element: AXUIElement?
    }

    struct Outcome {
        let title: String
        let detail: String?
    }

    private let logger = Logger(subsystem: "com.swaymun.ducky-access", category: "insertion")

    static func captureTarget() -> Target? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        var value: CFTypeRef?
        let root = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &value)
        let element = value.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        return Target(pid: app.processIdentifier, element: element)
    }

    func insert(_ text: String, completion: @escaping (Outcome) -> Void) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(Outcome(title: "No speech detected", detail: nil)); return
        }
        let pasteboard = NSPasteboard.general
        // Preserve all clipboard representations, but restore only after a
        // verified paste and only if nobody has copied something else since.
        let oldItems = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let copiedCount = pasteboard.changeCount
        func copied(_ reason: String) {
            logger.notice("Paste skipped: \(reason, privacy: .public)")
            completion(Outcome(title: "Copied — press ⌘V", detail: reason))
        }
        let permissions = ControlPermissions.read()
        guard !permissions.needsRepair else {
            copied("Re-add /Applications/DuckyAccess.app in Privacy & Security → Accessibility, enable it, then relaunch."); return
        }
        // Insert into the field focused NOW. Web editors often recreate their
        // accessibility objects while recording, so identity equality with
        // the field at recording start is not a reliable readiness check.
        guard let target = Self.captureTarget(), let element = target.element, Self.isEditable(element) else {
            copied("Focus a text field to insert dictation automatically."); return
        }
        let before = Self.value(element)
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            copied("Could not create a paste keystroke."); return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            let after = Self.value(element)
            let verified = after != nil && after != before && after!.contains(text)
            logger.info("Paste completed verified=\(verified) destinationPID=\(target.pid)")
            if verified {
                if pasteboard.changeCount == copiedCount {
                    pasteboard.clearContents()
                    if !oldItems.isEmpty { pasteboard.writeObjects(oldItems) }
                }
                completion(Outcome(title: "Inserted", detail: nil))
            } else {
                // Some editors don't expose their text through AX. Keep the
                // result available for manual paste instead of claiming success.
                completion(Outcome(title: "Paste sent — text also copied", detail: nil))
            }
        }
    }

    private static func value(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        var enabled: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled)
        if let enabled = enabled as? Bool, !enabled { return false }
        var role: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if ["AXTextField", "AXTextArea", "AXComboBox"].contains(role as? String ?? "") { return true }
        var selectedTextSettable = DarwinBoolean(false)
        _ = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &selectedTextSettable)
        return selectedTextSettable.boolValue
    }
}
