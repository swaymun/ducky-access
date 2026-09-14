import AppKit
import OSLog

final class AppSwitcher {
    private(set) var active = false
    private let commandKey: CGKeyCode = 55
    private let tabKey: CGKeyCode = 48
    private let source = CGEventSource(stateID: .privateState)
    private let eventTag = KeyboardOutput.eventTag
    private var expiry: DispatchWorkItem?
    private let logger = Logger(subsystem: "com.swaymun.ducky-access", category: "switcher")

    func begin() {
        guard !active, source != nil, CGPreflightPostEventAccess() else { return }
        active = true
        logger.info("Opening native app switcher")
        post(commandKey, down: true, flags: .maskCommand)
        post(tabKey, down: true, flags: .maskCommand)
        post(tabKey, down: false, flags: .maskCommand)
        refreshExpiry()
    }

    func next() {
        guard active else { return }
        post(tabKey, down: true, flags: .maskCommand)
        post(tabKey, down: false, flags: .maskCommand)
        refreshExpiry()
    }

    func previous() {
        guard active else { return }
        post(tabKey, down: true, flags: [.maskCommand, .maskShift])
        post(tabKey, down: false, flags: [.maskCommand, .maskShift])
        refreshExpiry()
    }

    func finish() {
        guard active else { return }
        post(commandKey, down: false, flags: [])
        active = false
        expiry?.cancel()
        expiry = nil
        logger.info("Closed native app switcher")
    }

    func cancel() {
        guard active else { return }
        post(53, down: true, flags: .maskCommand)
        post(53, down: false, flags: .maskCommand)
        finish()
    }

    private func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let source, let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: eventTag)
        event.post(tap: .cghidEventTap)
    }

    func filterEvent(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard active, event.getIntegerValueField(.eventSourceUserData) != eventTag else { return event }
        // Physical encoder scripts press/release Ctrl/Option/Shift between
        // steps. Dock must not see those releases as the end of Command-Tab.
        // The router reads their original flags first, so pad chords still work.
        if type == .flagsChanged { return nil }
        if type == .keyDown {
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            switch key {
            case 53: cancel()
            case 36, 76: finish()
            case 123: previous()
            case 124: next()
            case 48: event.flags.contains(.maskShift) ? previous() : next()
            default: cancel(); return event
            }
            return nil
        }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) { cancel() }
        return event
    }

    private func refreshExpiry() {
        expiry?.cancel()
        let expiry = DispatchWorkItem { [weak self] in self?.cancel() }
        self.expiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: expiry)
    }
}
