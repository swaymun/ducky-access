import Foundation
import IOKit.hid

final class DuckyPadDetector {
    static let vendorID = 0x0483
    static let productIDs = [0xd11c, 0xd11d]

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var started = false
    private var pollTimer: Timer?
    private var reportModifiers: UInt8 = 0
    private var reportPressedKeys = Set<UInt8>()
    var onChange: ((Bool) -> Void)?
    var onInputValue: ((UInt32, Int64) -> Void)?
    private(set) var connected = false

    func start() {
        guard !started else { return }
        started = true
        let matches = Self.productIDs.map { [kIOHIDVendorIDKey as String: Self.vendorID, kIOHIDProductIDKey as String: $0] }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let detector = Unmanaged<DuckyPadDetector>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                detector.connected = true
                detector.onChange?(true)
            }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let detector = Unmanaged<DuckyPadDetector>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                detector.connected = false
                detector.onChange?(false)
            }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard result == kIOReturnSuccess, let context else { return }
            let detector = Unmanaged<DuckyPadDetector>.fromOpaque(context).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(element) == 0x07 else { return }
            detector.onInputValue?(IOHIDElementGetUsage(element), Int64(IOHIDValueGetIntegerValue(value)))
        }, context)
        IOHIDManagerRegisterInputReportCallback(manager, { context, result, _, _, reportID, report, reportLength in
            guard result == kIOReturnSuccess, let context, reportLength >= 4 else { return }
            let detector = Unmanaged<DuckyPadDetector>.fromOpaque(context).takeUnretainedValue()
            detector.receiveReport(report, length: reportLength, reportID: reportID)
        }, context)
        _ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        refresh(notifyEvenIfUnchanged: true)
        // Some macOS privacy configurations deny IOHIDManagerOpen even when
        // the pad is visible to hidutil. Polling the matched device set keeps
        // hot-plug detection working without requiring direct HID reads.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func refresh(notifyEvenIfUnchanged: Bool = false) {
        let next = IOHIDManagerCopyDevices(manager).map { CFSetGetCount($0) > 0 } ?? false
        guard notifyEvenIfUnchanged || next != connected else { return }
        connected = next
        onChange?(next)
    }

    private func receiveReport(_ report: UnsafeMutablePointer<UInt8>, length: CFIndex, reportID: UInt32) {
        // The DuckyPad keyboard report is [report ID, modifiers, reserved,
        // key1...key6]. Some macOS paths include the report ID in the buffer;
        // accept both forms for driver-version compatibility.
        let includesReportID = report[0] == UInt8(truncatingIfNeeded: reportID)
        let offset = includesReportID ? 1 : 0
        guard length > offset + 2 else { return }
        let nextModifiers = report[offset]
        for bit in 0..<8 {
            let mask = UInt8(1 << bit)
            if (nextModifiers & mask) != (reportModifiers & mask) {
                onInputValue?(0xE0 + UInt32(bit), (nextModifiers & mask) == 0 ? 0 : 1)
            }
        }
        reportModifiers = nextModifiers

        let keyStart = offset + 2
        let keyEnd = min(length, keyStart + 6)
        var nextKeys = Set<UInt8>()
        if keyStart < keyEnd {
            for index in keyStart..<keyEnd {
                let usage = report[index]
                if usage != 0 { nextKeys.insert(usage) }
            }
        }
        for usage in nextKeys.subtracting(reportPressedKeys) { onInputValue?(UInt32(usage), 1) }
        for usage in reportPressedKeys.subtracting(nextKeys) { onInputValue?(UInt32(usage), 0) }
        reportPressedKeys = nextKeys
    }
}

enum DuckyProfile {
    static let name = "DuckyAccess"
    static let grid = [
        ["A", "B", "C", "D", "E"],
        ["F", "G", "H", "I", "J"],
        ["K", "L", "M", "N", "O"],
        ["NAV", "DICT", "CMD", "BKSP", "ESC"]
    ]
}
