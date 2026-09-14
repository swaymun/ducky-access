import AppKit
import WebKit

final class HelpPanelController {
    private var window: NSWindow?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 560, height: 610))
        view.loadHTMLString(Self.html, baseURL: nil)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Ducky Access Help"
        window.contentView = view
        window.center()
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    private static let html = """
    <!doctype html><meta charset="utf-8"><style>
    body{font:15px -apple-system,BlinkMacSystemFont,sans-serif;color:#172033;background:#f5f7fb;padding:28px;line-height:1.45}main{background:white;border:1px solid #e0e5ef;border-radius:18px;padding:26px;box-shadow:0 8px 28px #17203312}h1{font-size:25px;margin:0 0 5px}h2{font-size:16px;margin:24px 0 8px;color:#4658d8}table{border-collapse:collapse;width:100%}td{padding:7px;border-bottom:1px solid #edf0f5}kbd{background:#eef1f7;border:1px solid #d4dbe8;border-radius:5px;padding:2px 6px;font-weight:600}code{color:#4658d8}
    </style><main><h1>Ducky Access</h1><p>Accessibility hints, private English dictation, and voice commands.</p>
    <h2>Pad layout</h2><table>
    <tr><td><kbd>A</kbd>–<kbd>O</kbd></td><td>Type an accessibility hint code</td></tr>
    <tr><td><kbd>NAV</kbd></td><td>Show or hide hints</td></tr>
    <tr><td><kbd>DICT</kbd></td><td>Tap to start; tap again to insert cleaned text</td></tr>
    <tr><td><kbd>CMD</kbd></td><td>Tap to start; tap again to run a spoken command or shortcut</td></tr>
    <tr><td><kbd>ENTER</kbd></td><td>Send Return to the focused app; may submit a message</td></tr>
    <tr><td><kbd>ESC</kbd></td><td>Cancel or send Escape</td></tr></table>
    <h2>Knobs</h2><p><b>Volume knob:</b> turn for volume, press for mute.</p>
    <p><b>App knob:</b> turn to scroll when closed. Press to open the native <kbd>⌘Tab</kbd> switcher; turn to move through apps; press again or <kbd>ENTER</kbd> to activate. <kbd>ESC</kbd> cancels. It also cancels after 30 seconds without input.</p>
    <h2>Spoken shortcuts</h2><p>In <kbd>CMD</kbd> mode, say “Command T,” “Control Option Command T,” “Command Shift Tab,” or “press Enter.” Say one complete shortcut at a time; “Control Command Option” alone needs a key.</p>
    <p>Shortcuts act on the focused app like the keyboard, including shortcuts that submit or delete. <kbd>DICT</kbd> only types text; it never runs shortcuts.</p>
    <h2>Menu bar</h2><p>Choose model, reasoning, and speed; inspect Codex usage; play or copy the five newest dictations; or open the full local history.</p>
    <h2>Privacy</h2><p>Parakeet runs locally. Audio and transcripts are kept locally until you delete them. Literal shortcuts stay local. Luna receives only the finished transcript needed for cleanup or other command classification.</p></main>
    """
}
