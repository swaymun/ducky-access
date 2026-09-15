import ApplicationServices
import AppKit
import OSLog

enum NavigationActivation {
    private static let logger = Logger(subsystem: "com.swaymun.ducky-access", category: "navigation")
    // AXPress can acknowledge a request without delivering the pointer events
    // used by web tabs/menus. NAV is a click command: send ONE real click, not
    // AXPress followed by an unverified retry. Menu items retain AX activation.
    static func usesPress(role: String) -> Bool { role == "AXMenuItem" }

    static func clickPoint(frame: CGRect, screens: [CGRect]) -> CGPoint? {
        guard NavigationGeometry.usable(frame),
              let visible = screens.map({ frame.intersection($0) })
                .filter({ NavigationGeometry.usable($0) })
                .max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        // A spanning control's midpoint can lie in a gap between displays.
        return CGPoint(x: visible.midX, y: visible.midY)
    }

    /// Accept a hit on the target or its non-interactive text/image descendants,
    /// never a different/nested control (e.g. a tab's close button).
    static func hitMatches(_ hit: AXUIElement, target: AXUIElement, ticket: NavigationTicket,
                           parent: (AXUIElement) -> AXUIElement? = { NavigationScanner.axElement(NavigationScanner.attribute($0, kAXParentAttribute)) },
                           passive: (AXUIElement) -> Bool = isPassive) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        var current: AXUIElement? = hit
        var seen: [AXUIElement] = []
        for _ in 0..<16 {
            guard ticket.active, ProcessInfo.processInfo.systemUptime < deadline, let element = current,
                  !seen.contains(where: { CFEqual($0, element) }) else { return false }
            if CFEqual(element, target) { return true }
            seen.append(element)
            guard passive(element) else { return false }
            current = parent(element)
        }
        return false
    }

    static func isPassive(role: String, actions: [String], focusable: Bool) -> Bool {
        // Chromium exposes context-menu/scroll actions even on plain text.
        // Neither is invoked by a left click; AXPress and unknown actions are
        // still rejected so a nested interactive control cannot be selected.
        let nonClickActions: Set<String> = ["AXShowMenu", "AXScrollToVisible"]
        return ["AXStaticText", "AXImage", "AXGroup"].contains(role) && actions.allSatisfy(nonClickActions.contains) && !focusable
    }

    private static func isPassive(_ element: AXUIElement) -> Bool {
        guard let role = NavigationScanner.attribute(element, kAXRoleAttribute) as? String else { return false }
        var actions: CFArray?
        let actionResult = AXUIElementCopyActionNames(element, &actions)
        guard actionResult == .success, let actions = actions as? [String] else {
            logger.info("NAV hit descendant role=\(role, privacy: .public) actionsError=\(actionResult.rawValue)"); return false
        }
        var focusable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &focusable)
        logger.info("NAV hit descendant role=\(role, privacy: .public) actions=\(actions.joined(separator: ","), privacy: .public) focusable=\(focusable.boolValue) focusError=\(result.rawValue)")
        guard result == .success || result == .attributeUnsupported else { return false }
        return isPassive(role: role, actions: actions, focusable: focusable.boolValue)
    }

    static func hitTest(_ point: CGPoint, hint: AccessibilityHint, pid: pid_t, ticket: NavigationTicket) -> Bool {
        guard ticket.active else { return false }
        // Match the PID-targeted delivery below. Setting a timeout on the
        // system-wide element would change every AX client's default in this
        // process, including dictation insertion; never do that here.
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        var hit: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit)
        guard result == .success, let hit else {
            logger.info("NAV hit-test error=\(result.rawValue) pid=\(pid) x=\(point.x) y=\(point.y)"); return false
        }
        var hitPID: pid_t = 0
        guard AXUIElementGetPid(hit, &hitPID) == .success, hitPID == pid else {
            logger.info("NAV hit-test pid mismatch expected=\(pid) got=\(hitPID)"); return false
        }
        if !CFEqual(hit, hint.element) {
            let node = NavigationScanner.read(hit)
            logger.info("NAV hit-test different element role=\(node?.role ?? "unknown", privacy: .public) x=\(point.x) y=\(point.y) hitRect=\(String(describing: node?.frame), privacy: .public)")
        }
        return hitMatches(hit, target: hint.element, ticket: ticket)
    }

    static func dispatchClick(events: [CGEvent], ticket: NavigationTicket,
                              validateContext: () -> Bool, validateHit: () -> Bool,
                              post: (CGEvent) -> Void) -> Bool {
        guard events.count == 2, ticket.active, validateContext(), ticket.active, validateHit() else { return false }
        // No AX reads or main-queue hop between the final hit test and posting.
        // Do not hold the ticket lock during AX work: cancellation stays responsive.
        return ticket.performIfActive { events.forEach(post); return true } ?? false
    }

    // Construct both events before dispatch, so construction failure cannot
    // leave a mouse button held. Tests inspect these without posting to the OS.
    static func clickEvents(at point: CGPoint) -> [CGEvent]? {
        guard point.x.isFinite, point.y.isFinite, let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return nil }
        for event in [down, up] {
            event.flags = [] // Never inherit the pad's Hyper modifiers.
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.setIntegerValueField(.eventSourceUserData, value: KeyboardOutput.eventTag)
        }
        return [down, up]
    }
}
