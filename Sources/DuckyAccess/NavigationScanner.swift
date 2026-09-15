import AppKit
import ApplicationServices

enum NavigationGeometry {
    // AX uses top-left global points; AppKit uses bottom-left global points.
    // The origin belongs to the primary screen, NOT NSScreen.main (key window).
    static func axRect(fromAppKit rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }
    static func localRect(_ axRect: CGRect, screen: CGRect, primaryTop: CGFloat) -> CGRect? {
        let global = Self.axRect(fromAppKit: axRect, primaryTop: primaryTop)
        let clipped = global.intersection(screen)
        guard usable(clipped) else { return nil }
        return clipped.offsetBy(dx: -screen.minX, dy: -screen.minY)
    }
    static func usable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite && rect.width > 4 && rect.height > 4
    }
    static func labelRect(for frame: CGRect, in bounds: CGRect) -> CGRect {
        CGRect(x: min(max(frame.minX + 1, bounds.minX), bounds.maxX - 30),
               y: min(max(frame.maxY - 21, bounds.minY), bounds.maxY - 20), width: 30, height: 20)
    }
}

final class NavigationTicket {
    private let lock = NSLock()
    private var cancelled = false
    var active: Bool { lock.withLock { !cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
    func performIfActive<T>(_ action: () -> T) -> T? {
        lock.withLock { cancelled ? nil : action() }
    }
}

/// Main-thread generation gate: dismissed/replaced scans cannot resurrect UI.
final class NavigationLifetime {
    private(set) var current = NavigationTicket()
    func invalidate() { current.cancel(); current = NavigationTicket() }
    func accepts(_ ticket: NavigationTicket) -> Bool { current === ticket && ticket.active }
}

/// One running scan and at most one input-driven follow-up; no poll catch-up loop.
struct NavigationScanSchedule {
    private(set) var running = false
    private var pending = false
    mutating func begin(fallback: Bool) -> Bool {
        if running { if !fallback { pending = true }; return false }
        running = true; pending = false; return true
    }
    mutating func finish() -> Bool {
        running = false
        let again = pending; pending = false; return again
    }
    mutating func cancelPending() { pending = false }
}

struct NavigationElectronOptIn {
    private var attempts: [pid_t: (launchDate: Date, count: Int)] = [:]
    mutating func shouldAttempt(pid: pid_t, launchDate: Date) -> Bool {
        if attempts[pid]?.launchDate != launchDate { attempts[pid] = (launchDate, 0) }
        guard let current = attempts[pid], current.count < 3 else { return false }
        attempts[pid] = (launchDate, current.count + 1); return true
    }
    mutating func succeeded(pid: pid_t) {
        if let current = attempts[pid] { attempts[pid] = (current.launchDate, 3) }
    }
}

struct NavigationNode {
    let element: AXUIElement
    let role: String
    let frame: CGRect?
    let hidden: Bool
    let enabled: Bool
    let label: String
    let children: [AXUIElement]
    let document: String
    var supportsAction = true
}

struct NavigationSnapshot {
    let pid: pid_t
    let window: AXUIElement
    let frame: CGRect
    let document: String
    let webAreas: [(AXUIElement, String)]
    let hints: [AccessibilityHint]
    let visited: Int
    let limited: Bool
    let screens: [CGRect] // AX-global display rectangles used for this scan.
    func hasSameContext(as other: Self) -> Bool {
        pid == other.pid && CFEqual(window, other.window) && frame == other.frame && document == other.document && screens == other.screens &&
        webAreas.count == other.webAreas.count && zip(webAreas, other.webAreas).allSatisfy { CFEqual($0.0, $1.0) && $0.1 == $1.1 }
    }
    func matches(_ other: Self) -> Bool {
        hasSameContext(as: other) &&
        hints.count == other.hints.count && zip(hints, other.hints).allSatisfy { CFEqual($0.element, $1.element) && $0.frame == $1.frame && $0.label == $1.label }
    }
}

enum NavigationScanner {
    static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    static let actionableRoles: Set<String> = editableRoles.union(["AXButton", "AXLink", "AXMenuItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXSlider", "AXCell", "AXTab", "AXDisclosureTriangle"])
    private static let clippingRoles: Set<String> = ["AXScrollArea", "AXWebArea", "AXWindow"]
    private static let keys = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, "AXHidden", kAXEnabledAttribute,
                               kAXTitleAttribute, kAXDescriptionAttribute, "AXVisibleChildren", kAXChildrenAttribute, "AXURL"]

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.08)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    static func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    static func read(_ element: AXUIElement) -> NavigationNode? {
        AXUIElementSetMessagingTimeout(element, 0.08)
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, keys as CFArray, [], &values) == .success,
              let values = values as? [Any], values.count == keys.count, let role = values[0] as? String else { return nil }
        var frame: CGRect?
        if CFGetTypeID(values[1] as CFTypeRef) == AXValueGetTypeID(), CFGetTypeID(values[2] as CFTypeRef) == AXValueGetTypeID() {
            var point = CGPoint.zero, size = CGSize.zero
            if AXValueGetValue(values[1] as! AXValue, .cgPoint, &point), AXValueGetValue(values[2] as! AXValue, .cgSize, &size) {
                frame = CGRect(origin: point, size: size)
            }
        }
        let title = (values[5] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var supportsAction = editableRoles.contains(role)
        if actionableRoles.contains(role), !supportsAction {
            var actions: CFArray?
            supportsAction = AXUIElementCopyActionNames(element, &actions) == .success && (actions as? [String] ?? []).contains(kAXPressAction)
        }
        return NavigationNode(element: element, role: role, frame: frame, hidden: values[3] as? Bool == true,
                              enabled: values[4] as? Bool != false, label: title.isEmpty ? (values[6] as? String ?? "") : title,
                              children: (values[7] as? [AXUIElement]) ?? (values[8] as? [AXUIElement]) ?? [],
                              document: (values[9] as? URL)?.absoluteString ?? (values[9] as? String ?? ""), supportsAction: supportsAction)
    }

    static func scan(pid: pid_t, screens: [CGRect], ticket: NavigationTicket) -> NavigationSnapshot? {
        guard ticket.active else { return nil }
        let started = ProcessInfo.processInfo.systemUptime
        let app = AXUIElementCreateApplication(pid)
        guard let window = axElement(attribute(app, kAXFocusedWindowAttribute)), let node = read(window),
              let frame = node.frame, NavigationGeometry.usable(frame) else { return nil }
        let document = attribute(window, kAXDocumentAttribute) as? String ?? ""
        let result = collect(root: node, screens: screens, ticket: ticket, seconds: max(0, 0.65 - (ProcessInfo.processInfo.systemUptime - started)))
        guard ticket.active, let current = axElement(attribute(app, kAXFocusedWindowAttribute)), CFEqual(window, current),
              read(current)?.frame == frame, (attribute(current, kAXDocumentAttribute) as? String ?? "") == document else { return nil }
        return NavigationSnapshot(pid: pid, window: window, frame: frame, document: document, webAreas: result.webAreas,
                                  hints: result.hints, visited: result.visited, limited: result.limited, screens: screens)
    }

    struct Collection {
        var hints: [AccessibilityHint] = []
        var webAreas: [(AXUIElement, String)] = []
        var visited = 0
        var limited = false
    }

    // Injectable reads exercise the real traversal without AX permission/clicks.
    static func collect(root: NavigationNode, screens: [CGRect], ticket: NavigationTicket,
                        maxNodes: Int = 4000, maxHints: Int = 225, seconds: TimeInterval = 0.65,
                        readNode: (AXUIElement) -> NavigationNode? = read) -> Collection {
        var result = Collection()
        guard let windowFrame = root.frame else { return result }
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var stack: [(AXUIElement, CGRect, Int)] = [(root.element, windowFrame, 0)]
        var identities: [CFHashCode: [AXUIElement]] = [:]
        let alphabet = Array("ABCDEFGHIJKLMNO")
        while let (element, inheritedClip, depth) = stack.popLast() {
            guard ticket.active else { return Collection() }
            guard result.visited < maxNodes, result.hints.count < min(225, maxHints), ProcessInfo.processInfo.systemUptime < deadline else { result.limited = true; break }
            // Different wrappers can refer to the same remote AX element.
            let hash = CFHash(element)
            guard !(identities[hash] ?? []).contains(where: { CFEqual($0, element) }) else { continue }
            identities[hash, default: []].append(element)
            result.visited += 1
            guard let node = depth == 0 ? root : readNode(element) else { result.limited = true; continue }
            guard !node.hidden else { continue }
            var clip = inheritedClip
            if clippingRoles.contains(node.role), let frame = node.frame {
                guard NavigationGeometry.usable(frame) else { continue }
                clip = clip.intersection(frame)
                guard NavigationGeometry.usable(clip) else { continue }
            }
            if node.role == "AXWebArea" { result.webAreas.append((element, node.document)) }
            if actionableRoles.contains(node.role), node.supportsAction, node.enabled, let frame = node.frame, NavigationGeometry.usable(frame) {
                let visible = frame.intersection(clip)
                if NavigationGeometry.usable(visible), screens.contains(where: { NavigationGeometry.usable(visible.intersection($0)) }) {
                    let index = result.hints.count
                    result.hints.append(.init(code: String(alphabet[index / 15]) + String(alphabet[index % 15]), frame: visible, element: element, label: node.label))
                }
            }
            let available = max(0, maxNodes - result.visited - stack.count)
            if depth < 60 {
                if node.children.count > available { result.limited = true }
                for child in node.children.prefix(available).reversed() { stack.append((child, clip, depth + 1)) }
            } else if !node.children.isEmpty { result.limited = true }
        }
        return ticket.active ? result : Collection()
    }

    static func isCurrent(_ snapshot: NavigationSnapshot, hint: AccessibilityHint, ticket: NavigationTicket) -> Bool {
        guard ticket.active else { return false }
        // A fresh bounded walk proves the element is still in the selected
        // window/tab and visible. Old web-area handles alone do not prove that.
        guard let current = scan(pid: snapshot.pid, screens: snapshot.screens, ticket: ticket),
              current.hasSameContext(as: snapshot),
              current.hints.contains(where: { CFEqual($0.element, hint.element) && $0.frame == hint.frame && $0.label == hint.label }) else { return false }
        return ticket.active
    }
}
