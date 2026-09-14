import Foundation
import OSLog

final class KeyboardRouter {
    private var started = false
    private var modifiers: UInt8 = 0
    private var pressedKeys = Set<UInt32>()
    private let logger = Logger(subsystem: "com.swaymun.ducky-access", category: "keyboard")

    var onAction: ((PadAction) -> Void)?

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
    }

    func stop() {
        modifiers = 0
        pressedKeys.removeAll()
        started = false
    }

    private func receive(usage: UInt32, value: Int64) {
        switch usage {
        case 0xE0...0xE7:
            let bit = UInt8(1 << (usage - 0xE0))
            if value != 0 { modifiers |= bit } else { modifiers &= ~bit }
        default:
            guard usage <= UInt32(UInt8.max) else { return }
            if value == 0 {
                pressedKeys.remove(usage)
            } else if pressedKeys.insert(usage).inserted {
                route(usage: UInt8(usage), modifiers: modifiers)
            }
        }
    }

    private func route(usage: UInt8, modifiers: UInt8) {
        guard let function = functionByUsage[usage] else { return }
        let allModifiers = modifiers == 0x0F // Ctrl + Shift + Alt + GUI
        let encoderModifiers = modifiers == 0x07 // Ctrl + Shift + Alt
        guard allModifiers || encoderModifiers else { return }

        logger.info("Received DuckyPad HID usage=\(usage) function=\(function) modifiers=\(modifiers)")

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
    }

    private func emit(_ action: PadAction) {
        DispatchQueue.main.async { [weak self] in self?.onAction?(action) }
    }
}
