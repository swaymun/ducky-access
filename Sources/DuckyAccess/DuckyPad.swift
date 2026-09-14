import Foundation
import IOKit.hid

final class DuckyPadDetector {
    static let vendorID = 0x0483
    static let productIDs = [0xd11c, 0xd11d]

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var started = false
    private var pollTimer: Timer?
    var onChange: ((Bool) -> Void)?
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
