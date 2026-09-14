import AppKit
import Carbon.HIToolbox

final class KeyboardRouter {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var onAction: ((PadAction) -> Void)?

    private let keyCodes: [Int: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8,
        101: 9, 109: 10, 103: 11, 111: 12, 105: 13, 107: 14, 113: 15,
        106: 16, 64: 17, 79: 18, 80: 19, 90: 20, 87: 21, 88: 22, 110: 23,
        117: 24
    ]

    func start() {
        guard tap == nil else { return }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let router = Unmanaged<KeyboardRouter>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = router.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }
                let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
                guard let function = router.keyCodes[code] else { return Unmanaged.passUnretained(event) }
                let flags = event.flags.intersection(.maskShift.union(.maskControl).union(.maskCommand).union(.maskAlternate))
                let all = flags == [.maskShift, .maskControl, .maskCommand, .maskAlternate]
                let encoder = flags == [.maskShift, .maskControl, .maskAlternate]
                guard all || encoder else { return Unmanaged.passUnretained(event) }
                if type == .keyDown {
                    if all {
                        let letters = Array("ABCDEFGHIJKLMNO")
                        if function <= 15 { router.emit(.hint(letters[function - 1])) }
                        else if function == 16 { router.emit(.navigate) }
                        else if function == 17 { router.emit(.dictate) }
                        else if function == 18 { router.emit(.command) }
                        else if function == 19 { router.emit(.backspace) }
                        else if function == 20 { router.emit(.escape) }
                    } else {
                        switch function {
                        case 21: router.emit(.volumeUp)
                        case 22: router.emit(.volumeDown)
                        case 23: router.emit(.mute)
                        case 13: router.emit(.scrollUp)
                        case 14: router.emit(.scrollDown)
                        case 15: router.emit(.appSwitcher)
                        default: break
                        }
                    }
                }
                return nil
            }, userInfo: context
        )
        guard let tap else { return }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
    }

    private func emit(_ action: PadAction) {
        DispatchQueue.main.async { [weak self] in self?.onAction?(action) }
    }
}
