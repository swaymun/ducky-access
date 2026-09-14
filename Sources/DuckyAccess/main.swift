import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DuckyAccessController()
    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start(showHelpOnLaunch: CommandLine.arguments.contains("--demo"))
    }
    func applicationWillTerminate(_ notification: Notification) { controller.appSwitcher.cancel(); controller.keyboard.stop(); controller.appServer.stop() }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
