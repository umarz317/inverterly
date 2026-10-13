import SwiftUI
import InverterCore
import InverterUI

/// The iPhone app: sign-in, then the Now, Today and History tabs, reading while the app is in front.
@main
struct InverterlyApp: App {
    @StateObject private var store = AppStore(provider: Self.provider())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PhoneRootView(store: store)
                .onAppear {
                    // Keep today's chart and the history current when the app comes back to the front.
                    store.showToday = true
                    store.showHistory = true
                }
                // "Open" drives the faster polling, the hero's animation and catching up on return.
                .onChange(of: scenePhase, initial: true) { _, phase in store.panelOpen = phase == .active }
        }
    }

    private static func provider() -> SnapshotProviding {
        #if DEBUG
        // `-demo` shows made-up readings, for working on the layout without an account.
        if CommandLine.arguments.contains("-demo") { return DemoProvider() }
        #endif
        return InverterService()
    }
}
