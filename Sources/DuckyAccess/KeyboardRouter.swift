import AppKit
import Carbon.HIToolbox
import OSLog

final class KeyboardRouter {
    private var started = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tapRetry: DispatchWorkItem?
    private var tapRetryAttempts = 0
    private var modifiers: UInt8 = 0
    private var pressedKeys = Set<UInt32>()
    private let logger = Logger(subsystem: "com.swaymun.ducky-access", category: "keyboard")
    private let functionByKeyCode: [CGKeyCode: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8,
        101: 9, 109: 10, 103: 11, 111: 12, 105: 13, 107: 14, 113: 15,
        106: 16, 64: 17, 79: 18, 80: 19, 90: 20, 87: 21, 88: 22, 110: 23,
        117: 24
    ]

    var onAction: ((PadAction) -> Void)?

    func refreshPermissions() {
        guard started, tap == nil, CGPreflightPostEventAccess() else { return }
        tapRetryAttempts = 0
        startEventTap()
    }

    // USB HID usages for F1-F12 are 0x3A-0x45; F13-F24 are 0x68-0x73.
    private let functionByUsage: [UInt8: Int] = {
        var result: [UInt8: Int] = [:]
        for index in 0..<12 { result[0x3A + UInt8(index)] = index + 1 }
        for index in 0..<12 { result[0x68 + UInt8(index)] = index + 13 }
        return result
    }()

    func start(using detector: DuckyPadDetector) {
        guard !started else { return }
        started = true
        detector.onInputValue = { [weak self] usage, value in
            self?.receive(usage: usage, value: value)
        }
        startEventTap()
    }

    func stop() {
        tapRetry?.cancel()
        tapRetry = nil
        tapRetryAttempts = 0
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
        modifiers = 0
        pressedKeys.removeAll()
        started = false
    }

    private func receive(usage: UInt32, value: Int64) {
        // The event tap and HID callback both see each physical press. Choose
        // one source, rather than a time window: AX collection can block the
        // main run loop long enough for the second copy to escape a debounce.
        guard tap == nil else { return }
        switch usage {
        case 0xE0...0xE7:
            let bit = UInt8(1 << (usage - 0xE0))
            if value != 0 { modifiers |= bit } else { modifiers &= ~bit }
        default:
            guard usage <= UInt32(UInt8.max) else { return }
            if value == 0 {
                pressedKeys.remove(usage)
            } else if pressedKeys.insert(usage).inserted {
                guard let function = functionByUsage[UInt8(usage)] else { return }
                _ = route(function: function, modifiers: modifiers)
            }
        }
    }

    private func route(function: Int, modifiers: UInt8) -> Bool {
        let allModifiers = modifiers == 0x0F // Ctrl + Shift + Alt + GUI
        let encoderModifiers = modifiers == 0x07 // Ctrl + Shift + Alt
        guard allModifiers || encoderModifiers else { return false }

        logger.info("Received DuckyPad input function=\(function) modifiers=\(modifiers)")

        if allModifiers {
            let letters = Array("ABCDEFGHIJKLMNO")
            if function <= 15 { emit(.hint(letters[function - 1])) }
            else if function == 16 { emit(.navigate) }
            else if function == 17 { emit(.dictate) }
            else if function == 18 { emit(.command) }
            else if function == 19 { emit(.backspace) }
            else if function == 20 { emit(.escape) }
        } else {
            switch function {
            case 21: emit(.volumeUp)
            case 22: emit(.volumeDown)
            case 23: emit(.mute)
            case 13: emit(.scrollUp)
            case 14: emit(.scrollDown)
            case 15: emit(.appSwitcher)
            default: break
            }
        }
        return true
    }

    private func emit(_ action: PadAction) {
        DispatchQueue.main.async { [weak self] in self?.onAction?(action) }
    }

    private func startEventTap() {
        guard tap == nil else { return }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let router = Unmanaged<KeyboardRouter>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = router.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }
                let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                guard let function = router.functionByKeyCode[code] else { return Unmanaged.passUnretained(event) }
                let flags = event.flags.intersection([.maskShift, .maskControl, .maskCommand, .maskAlternate])
                let allModifiers: UInt8 = flags == [.maskShift, .maskControl, .maskCommand, .maskAlternate] ? 0x0F : 0
                let encoderModifiers: UInt8 = flags == [.maskShift, .maskControl, .maskAlternate] ? 0x07 : 0
                guard allModifiers != 0 || encoderModifiers != 0 else { return Unmanaged.passUnretained(event) }
                if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    _ = router.route(function: function, modifiers: allModifiers != 0 ? allModifiers : encoderModifiers)
                }
                return nil
            },
            userInfo: context
        )
        guard let tap else {
            tapRetryAttempts += 1
            if tapRetryAttempts == 1 {
                logger.error("DuckyPad keyboard fallback unavailable; direct HID input remains active")
            }
            if tapRetryAttempts <= 3 {
                scheduleTapRetry()
            } else if tapRetryAttempts == 4 {
                logger.info("DuckyPad keyboard fallback disabled after retries; direct HID input remains active")
            }
            return
        }
        tapRetry?.cancel()
        tapRetry = nil
        tapRetryAttempts = 0
        modifiers = 0
        pressedKeys.removeAll()
        logger.info("DuckyPad event tap active; HID routing is standby")
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func scheduleTapRetry() {
        guard tapRetry == nil, started else { return }
        let retry = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.tapRetry = nil
            self.startEventTap()
        }
        tapRetry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: retry)
    }
}
