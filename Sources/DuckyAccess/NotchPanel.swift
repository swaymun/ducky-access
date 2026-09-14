import AppKit

final class NotchPanelController {
    private let panel: NSPanel
    private let modeLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(labelWithString: "")
    private let waveform = WaveformView(frame: .zero)
    private var timer: Timer?

    init() {
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 460, height: 104), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let visual = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        visual.material = .hudWindow
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 24
        visual.layer?.masksToBounds = true
        panel.contentView = visual
        modeLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        modeLabel.textColor = .secondaryLabelColor
        textLabel.font = .systemFont(ofSize: 15, weight: .regular)
        textLabel.textColor = .labelColor
        textLabel.lineBreakMode = .byTruncatingTail
        waveform.wantsLayer = true
        visual.addSubview(modeLabel)
        visual.addSubview(waveform)
        visual.addSubview(textLabel)
        modeLabel.frame = CGRect(x: 24, y: 72, width: 410, height: 18)
        waveform.frame = CGRect(x: 24, y: 28, width: 110, height: 28)
        textLabel.frame = CGRect(x: 148, y: 29, width: 285, height: 28)
    }

    func show(mode: RecordingMode) {
        modeLabel.stringValue = mode == .dictate ? "DICTATION" : "COMMAND"
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

    func showResult(_ text: String, status: String) {
        timer?.invalidate(); timer = nil
        waveform.active = false
        modeLabel.stringValue = status.uppercased()
        textLabel.stringValue = text
        textLabel.toolTip = text
        position()
        panel.orderFrontRegardless()
    }

    func hide() {
        timer?.invalidate(); timer = nil
        panel.orderOut(nil)
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        panel.setFrameOrigin(CGPoint(x: screen.frame.midX - panel.frame.width / 2, y: screen.frame.maxY - panel.frame.height - 20))
    }
}

final class WaveformView: NSView {
    var active = false
    var phase: CGFloat = 0
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        for index in 0..<18 {
            let x = CGFloat(index) * 6
            let height = active ? 6 + abs(sin(phase + CGFloat(index) * 0.6)) * 20 : 5
            NSBezierPath(roundedRect: CGRect(x: x, y: (bounds.height - height) / 2, width: 3, height: height), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
