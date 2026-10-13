import AppKit
import InverterCore
import InverterUI

/// InverterBar lives only in the menu bar: no Dock icon, no main window.
///
/// Launch flags, for trying it out and for recording:
///   --demo   cycle through made-up readings instead of asking the inverter cloud
///   --open   open the panel as soon as the app starts
///   --tour   open the panel, then open and close its sections on a timer
///   --style  device, flow or scene: the illustration for this run only
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: AppStore?
    private var status: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        let demo = arguments.contains("--demo")
        let provider: SnapshotProviding = demo ? DemoProvider() : InverterService()
        // `--style device|flow|scene` forces the illustration for this run without saving it.
        let forced = arguments.firstIndex(of: "--style").flatMap { index in
            index + 1 < arguments.count ? HeroStyle(rawValue: arguments[index + 1]) : nil
        }
        let store = AppStore(provider: provider, isDemo: demo, heroStyle: forced)
        let status = StatusItemController(store: store)
        self.store = store
        self.status = status
        store.start()

        let tour = arguments.contains("--tour")
        guard tour || arguments.contains("--open") else { return }
        status.staysOpen = true
        after(1.0) {
            status.open()
            // With INVERTERBAR_DEBUG set, print the panel's window number so a script can capture just that window.
            if ProcessInfo.processInfo.environment["INVERTERBAR_DEBUG"] != nil, let number = status.panelWindowNumber {
                print("PANEL \(number)")
                fflush(stdout)
            }
        }
        guard tour else { return }
        startTourWhenLive(store: store, waited: 0)
    }

    /// The tour's clock starts at the first reading, so a slow first answer from the cloud does
    /// not use it up while the panel still says "Reading your inverter".
    private func startTourWhenLive(store: AppStore, waited: Double) {
        guard store.snapshot != nil || waited > 30 else {
            after(0.25) { self.startTourWhenLive(store: store, waited: waited + 0.25) }
            return
        }
        after(4.0) { store.showToday = true }
        after(8.0) { store.showDetails = true }
        after(12.0) { store.showToday = false; store.showDetails = false }
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
