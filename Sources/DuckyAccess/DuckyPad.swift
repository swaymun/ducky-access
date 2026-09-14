import Foundation
import IOKit.hid
import OSLog

final class DuckyPadDetector {
    static let vendorID = 0x0483
    static let productIDs = [0xd11c, 0xd11d]

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var started = false
    private var pollTimer: Timer?
    private var reportModifiers: UInt8 = 0
    private var reportPressedKeys = Set<UInt8>()
    private var reportBuffers: [ObjectIdentifier: UnsafeMutablePointer<UInt8>] = [:]
    private var devices: [ObjectIdentifier: IOHIDDevice] = [:]
    private let logger = Logger(subsystem: "com.swaymun.ducky-access", category: "hid")
    var onChange: ((Bool) -> Void)?
    var onInputValue: ((UInt32, Int64) -> Void)?
    private(set) var connected = false

    func start() {
        guard !started else { return }
        started = true
        let matches = Self.productIDs.map {
            [
                kIOHIDVendorIDKey as String: Self.vendorID,
                kIOHIDProductIDKey as String: $0,
                kIOHIDPrimaryUsagePageKey as String: 0x01,
                kIOHIDPrimaryUsageKey as String: 0x06
            ]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let detector = Unmanaged<DuckyPadDetector>.fromOpaque(context).takeUnretainedValue()
            detector.attach(device)
            DispatchQueue.main.async {
                detector.connected = true
                detector.onChange?(true)
            }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let detector = Unmanaged<DuckyPadDetector>.fromOpaque(context).takeUnretainedValue()
            detector.detach(device)
            DispatchQueue.main.async {
                detector.connected = false
                detector.onChange?(false)
            }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let managerResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in set {
                attach(device)
            }
            logger.info("DuckyPad keyboard manager openResult=\(managerResult, privacy: .public) matchedInterfaces=\(set.count, privacy: .public)")
        } else {
            logger.info("DuckyPad keyboard manager openResult=\(managerResult, privacy: .public) matchedInterfaces=0")
        }
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

    private func attach(_ device: IOHIDDevice) {
        let key = ObjectIdentifier(device)
        guard reportBuffers[key] == nil else { return }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        buffer.initialize(repeating: 0, count: 64)
        reportBuffers[key] = buffer
        devices[key] = device

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, result, _, _, reportID, report, reportLength in
            guard result == kIOReturnSuccess, let context, reportLength >= 4 else { return }
            let detector = Unmanaged<DuckyPadDetector>.fromOpaque(context).takeUnretainedValue()
            detector.receiveReport(report, length: reportLength, reportID: reportID)
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        logger.info("Attached DuckyPad keyboard interface openResult=\(openResult, privacy: .public)")
    }

    private func detach(_ device: IOHIDDevice) {
        let key = ObjectIdentifier(device)
        guard reportBuffers[key] != nil else { return }
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        reportBuffers.removeValue(forKey: key)?.deallocate()
        devices.removeValue(forKey: key)
        if devices.isEmpty {
            reportModifiers = 0
            reportPressedKeys.removeAll()
        }
        logger.info("Detached DuckyPad keyboard interface")
    }

    private func emitUsage(_ usage: UInt32, value: Int64) {
        DispatchQueue.main.async { [weak self] in
            self?.onInputValue?(usage, value)
        }
    }

    private func receiveReport(_ report: UnsafeMutablePointer<UInt8>, length: CFIndex, reportID: UInt32) {
        // The DuckyPad keyboard report is [report ID, modifiers, reserved,
        // key1...key6]. Some macOS paths include the report ID in the buffer;
        // accept both forms for driver-version compatibility.
        let includesReportID = report[0] == UInt8(truncatingIfNeeded: reportID)
        let offset = includesReportID ? 1 : 0
        guard length > offset + 2 else { return }
        let nextModifiers = report[offset]
        logger.info("DuckyPad report received reportID=\(reportID, privacy: .public) length=\(length, privacy: .public) modifiers=\(nextModifiers, privacy: .public)")
        for bit in 0..<8 {
            let mask = UInt8(1 << bit)
            if (nextModifiers & mask) != (reportModifiers & mask) {
                emitUsage(0xE0 + UInt32(bit), value: (nextModifiers & mask) == 0 ? 0 : 1)
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
        let newKeys = nextKeys.subtracting(reportPressedKeys)
        if !newKeys.isEmpty {
            logger.info("DuckyPad usage down=\(newKeys.sorted().map(String.init).joined(separator: ","), privacy: .public)")
        }
        for usage in newKeys { emitUsage(UInt32(usage), value: 1) }
        for usage in reportPressedKeys.subtracting(nextKeys) { emitUsage(UInt32(usage), value: 0) }
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
