import AppKit
import InverterCore
import InverterUI

/// InverterBar lives only in the menu bar: no Dock icon, no main window.
///
/// Launch flags:
///   --open   open the panel as soon as the app starts
///   --style  device, flow or scene: the illustration for this run only
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: AppStore?
    private var status: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        // `--style device|flow|scene` forces the illustration for this run without saving it.
        let forced = arguments.firstIndex(of: "--style").flatMap { index in
            index + 1 < arguments.count ? HeroStyle(rawValue: arguments[index + 1]) : nil
        }
        let store = AppStore(provider: InverterService(), heroStyle: forced)
        let status = StatusItemController(store: store)
        self.store = store
        self.status = status
        store.start()

        guard arguments.contains("--open") else { return }
        status.staysOpen = true
        after(1.0) {
            status.open()
            // With INVERTERBAR_DEBUG set, print the panel's window number so a script can capture just that window.
            if ProcessInfo.processInfo.environment["INVERTERBAR_DEBUG"] != nil, let number = status.panelWindowNumber {
                print("PANEL \(number)")
                fflush(stdout)
            }
        }
    }

    private func after(_ seconds: Double, _ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(action) }
    }
}

@main
enum InverterBarMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
