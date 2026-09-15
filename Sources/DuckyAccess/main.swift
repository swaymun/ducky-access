import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DuckyAccessController()
    private var clickProbe: NavigationClickProbe?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--nav-click-probe") {
            clickProbe = NavigationClickProbe(); clickProbe?.show(); return
        }
        controller.start(showHelpOnLaunch: CommandLine.arguments.contains("--demo"))
    }
    func applicationWillTerminate(_ notification: Notification) { controller.cancelCommand(); controller.navigator.close(); controller.appSwitcher.cancel(); controller.keyboard.stop(); controller.appServer.stop() }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
