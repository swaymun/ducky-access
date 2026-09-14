import AppKit
import OSLog

final class NotchPanelController {
    private let panel: NSPanel
    private let modeLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(labelWithString: "")
    private let waveform = WaveformView(frame: .zero)
    private var timer: Timer?
    private var dismissWork: DispatchWorkItem?
    private var dismissed = false
    var onDismiss: (() -> Void)?
    var commandCancellable = false {
        didSet {
            panel.contentView?.setAccessibilityLabel(commandCancellable ? "Stop command" : "Dismiss dictation preview")
            panel.contentView?.toolTip = commandCancellable ? "Click to stop this command. Completed actions are not undone." : "Click to dismiss"
        }
    }
    private let logger = Logger(subsystem: "com.swaymun.ducky-access", category: "notch")

    init() {
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 96), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let visual = DismissibleNotchView(frame: panel.contentView?.bounds ?? .zero)
        visual.onDismiss = { [weak self] in
            self?.dismissed = true
            self?.hide()
            self?.logger.info("Notch dismissed by click")
            self?.onDismiss?()
        }
        visual.setAccessibilityElement(true)
        visual.setAccessibilityRole(.button)
        visual.setAccessibilityLabel("Dismiss dictation preview")
        visual.toolTip = "Click to dismiss"
        visual.wantsLayer = true
        visual.layer?.backgroundColor = NSColor.black.cgColor
        visual.layer?.cornerRadius = 16
        visual.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        visual.layer?.masksToBounds = true
        panel.contentView = visual
        modeLabel.font = .systemFont(ofSize: 10, weight: .medium)
        modeLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        modeLabel.lineBreakMode = .byTruncatingTail
        textLabel.font = .systemFont(ofSize: 12, weight: .medium)
        textLabel.textColor = .white
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 2
        waveform.wantsLayer = true
        visual.addSubview(modeLabel)
        visual.addSubview(waveform)
        visual.addSubview(textLabel)
    }

    func show(mode: RecordingMode) {
        dismissWork?.cancel()
        dismissWork = nil
        dismissed = false
        modeLabel.stringValue = mode == .dictate ? "Dictation" : "Command"
        textLabel.stringValue = "Listening…"
        waveform.active = true
        position()
        panel.orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.waveform.phase += 0.35
            self?.waveform.needsDisplay = true
        }
    }

    func update(text: String) {
        textLabel.stringValue = text.isEmpty ? "Listening…" : text
    }

    func showResult(_ text: String, status: String, dismissAfter: TimeInterval? = nil) {
        dismissWork?.cancel()
        dismissWork = nil
        timer?.invalidate(); timer = nil
        waveform.active = false
        modeLabel.stringValue = status
        textLabel.stringValue = text
        textLabel.toolTip = text
        if !dismissed {
            position()
            panel.orderFrontRegardless()
            if let dismissAfter {
                let work = DispatchWorkItem { [weak self] in
                    self?.hide()
                    self?.logger.info("Notch automatically dismissed")
                }
                dismissWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + dismissAfter, execute: work)
            }
        }
    }

    func hide() {
        dismissWork?.cancel()
        dismissWork = nil
        timer?.invalidate(); timer = nil
        panel.orderOut(nil)
    }

    private func position() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let notchWidth: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = right.minX - left.maxX
        } else { notchWidth = 200 }
        let width = notchWidth > 0 ? notchWidth : 200
        let height = screen.safeAreaInsets.top + 64
        panel.setFrame(CGRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height), display: true)
        modeLabel.frame = CGRect(x: 12, y: 43, width: width - 24, height: 13)
        waveform.isHidden = !waveform.active
        waveform.frame = CGRect(x: 12, y: 17, width: 32, height: 18)
        let textX: CGFloat = waveform.active ? 52 : 12
        textLabel.frame = CGRect(x: textX, y: 9, width: width - textX - 12, height: 30)
        logger.info("Notch shown width=\(width) height=\(height)")
    }
}

private final class DismissibleNotchView: NSView {
    var onDismiss: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func mouseDown(with event: NSEvent) { onDismiss?() }
    override func accessibilityPerformPress() -> Bool { onDismiss?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

final class WaveformView: NSView {
    var active = false
    var phase: CGFloat = 0
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        for index in 0..<7 {
            let x = CGFloat(index) * bounds.width / 7
            let height = active ? 3 + abs(sin(phase + CGFloat(index) * 0.6)) * (bounds.height - 3) : 3
            NSBezierPath(roundedRect: CGRect(x: x, y: (bounds.height - height) / 2, width: 2, height: height), xRadius: 1, yRadius: 1).fill()
        }
    }
}
