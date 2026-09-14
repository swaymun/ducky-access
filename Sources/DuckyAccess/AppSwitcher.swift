import AppKit

final class AppSwitcher {
    private(set) var active = false
    private let commandKey: CGKeyCode = 55
    private let tabKey: CGKeyCode = 48
    private let shiftKey: CGKeyCode = 56

    func begin() {
        guard !active else { return }
        active = true
        post(commandKey, down: true, flags: .maskCommand)
        post(tabKey, down: true, flags: .maskCommand)
        post(tabKey, down: false, flags: .maskCommand)
    }

    func next() {
        guard active else { return }
        post(tabKey, down: true, flags: .maskCommand)
        post(tabKey, down: false, flags: .maskCommand)
    }

    func previous() {
        guard active else { return }
        post(shiftKey, down: true, flags: [.maskCommand, .maskShift])
        post(tabKey, down: true, flags: [.maskCommand, .maskShift])
        post(tabKey, down: false, flags: [.maskCommand, .maskShift])
        post(shiftKey, down: false, flags: .maskCommand)
    }

    func finish() {
        guard active else { return }
        post(commandKey, down: false, flags: [])
        active = false
    }

    func cancel() {
        guard active else { return }
        post(53, down: true, flags: .maskCommand)
        post(53, down: false, flags: .maskCommand)
        finish()
    }

    private func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
