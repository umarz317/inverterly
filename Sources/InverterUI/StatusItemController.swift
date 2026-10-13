import AppKit
import SwiftUI
import Combine
import InverterCore

/// Owns the menu bar item and the panel that drops from it.
///
/// This is a plain `NSStatusItem` and a borderless panel, not SwiftUI's `MenuBarExtra`, for three
/// reasons: the app can open and close its own panel (so it can be tested and toured), a click
/// inside the panel or its menus never dismisses it, and the panel keeps its top edge under the
/// menu bar when its content changes height.
@MainActor
public final class StatusItemController: NSObject {
    private let store: AppStore
    private let statusItem: NSStatusItem
    private let layout = PanelLayout()
    private var panel: PanelWindow?
    private var hosting: NSHostingController<PanelRoot>?
    /// Clips the SwiftUI content to the window while the window animates to a new height.
    private var clipView: NSView?
    /// Height the window currently gives the content.
    private var contentHeight: CGFloat = 0
    private var cancellables: Set<AnyCancellable> = []
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Top-left corner of the open panel in screen coordinates. Resizes pivot on this point.
    private var topLeft = NSPoint.zero
    /// What the status item is showing, so an unchanged icon is not redrawn.
    private var shownIcon = ""
    private var closedByOutsideClickAt = Date.distantPast

    public private(set) var isOpen = false
    /// When true, clicking elsewhere does not close the panel. Used by `--open`,
    /// where the panel has to stay up while something else is being used or recorded.
    public var staysOpen = false

    public init(store: AppStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemPressed(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])   // open on press, like the system's own items
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        }
        // objectWillChange fires before the new values are set, so read them on the next run-loop turn.
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshLabel() }
            .store(in: &cancellables)
        store.iconPhaseChanged
            .sink { [weak self] _ in self?.refreshLabel() }
            .store(in: &cancellables)
        refreshLabel()
    }

    /// The panel's window number while it is on screen, for tools that capture a single window.
    public var panelWindowNumber: Int? { isOpen ? panel?.windowNumber : nil }

    // MARK: Menu bar label

    private func refreshLabel() {
        guard let button = statusItem.button else { return }
        let reading = store.snapshot
        let stale = store.readingIsStale
        let power = reading?.batteryPowerW ?? 0
        let activity: MenuBarIcon.Activity = stale ? .unknown : power > 30 ? .charging : power < -30 ? .discharging : .idle
        let level = stale ? nil : reading?.batteryPercent.map { $0 / 100 }
        let solar = !stale && (reading?.pvPowerW ?? 0) > 20
        let phase = store.animateIcon ? store.iconPhase : 0

        // Setting the image makes macOS re-render the item for every display, so only do it
        // when the picture would actually differ.
        let icon = "\(level.map { Int(($0 * 100).rounded()) } ?? -1)|\(activity)|\(solar)|\(phase)"
        if icon != shownIcon {
            shownIcon = icon
            button.image = MenuBarIcon.image(level: level, activity: activity, solar: solar, phase: phase)
        }
        let title = store.menuBarText ?? ""
        if button.title != title { button.title = title }
        button.setAccessibilityLabel(accessibilityText(reading, stale: stale))
    }

    private func accessibilityText(_ reading: EnergySnapshot?, stale: Bool) -> String {
        guard let reading else { return "InverterBar, no data" }
        guard !stale else { return "InverterBar, no recent data" }
        let battery = reading.batteryPercent.map { "battery \(Int($0.rounded())) percent" } ?? "battery unknown"
        return "InverterBar, \(reading.mode.label.lowercased()), \(battery), load \(PowerFormat.watts(reading.loadPowerW))"
    }

    // MARK: Open and close

    @objc private func statusItemPressed(_ sender: Any?) {
        // If macOS also delivered this press to the outside-click monitor, the panel has just
        // been closed by it. Opening again here would make a closing click reopen the panel.
        guard Date().timeIntervalSince(closedByOutsideClickAt) > 0.3 else { return }
        toggle()
    }

    public func toggle() { isOpen ? close() : open() }

    public func open() {
        guard !isOpen else { return }
        let panel = makePanelIfNeeded()
        guard hosting != nil else { return }

        let (anchor, screen) = anchorAndScreen()
        let area = screen.visibleFrame
        let top = (screen.frame.maxY - Self.menuBarHeight(on: screen, itemHeight: anchor.height) - 5).rounded()
        // Never taller than the space under the menu bar; past that the content scrolls.
        layout.maxHeight = max(240, top - area.minY - 8)
        let size = measuredSize()
        contentHeight = size.height
        let x = min(max(anchor.midX - size.width / 2, area.minX + 8), area.maxX - size.width - 8)
        topLeft = NSPoint(x: x.rounded(), y: top)
        let frame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)

        isOpen = true
        store.panelOpen = true
        statusItem.button?.highlight(true)
        installMonitors()
        panel.setFrame(frame, display: false)
        pinContent()

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            panel.makeKey()
            panel.invalidateShadow()
        } else {
            // Drop in: start a few points high and transparent, settle into place.
            panel.alphaValue = 0
            panel.setFrame(frame.offsetBy(dx: 0, dy: 7), display: true)
            panel.orderFrontRegardless()
            panel.makeKey()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { panel.invalidateShadow() }
        }
        // The press that opened the panel un-highlights the button on mouse-up, so set it again after.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isOpen else { return }
            self.statusItem.button?.highlight(true)
        }
    }

    public func close() {
        guard isOpen, let panel else { return }
        isOpen = false
        store.panelOpen = false
        statusItem.button?.highlight(false)
        removeMonitors()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isOpen else { return }
                panel.orderOut(nil)
            }
        })
    }

    // MARK: Panel

    private static let panelWidth: CGFloat = 380

    /// Height of the hosting view. It is fixed and taller than the panel can ever be, so the
    /// SwiftUI content is never resized from outside: the window alone decides how much shows.
    /// (Resizing the hosting view while SwiftUI was animating a section made the content jump.)
    private static let hostHeight: CGFloat = 1400

    private func makePanelIfNeeded() -> PanelWindow {
        if let panel { return panel }
        let controller = NSHostingController(rootView: PanelRoot(store: store, layout: layout) { [weak self] height in
            self?.contentHeightChanged(height)
        })

        let panel = PanelWindow(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 520),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // The app is never the active one, and tooltips are normally shown only by the active app.
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.setAccessibilityTitle("InverterBar")

        // The SwiftUI content sits in a clip view, pinned to its top edge at a fixed height.
        // It never stretches with the window: when the window animates taller or shorter the
        // content is revealed or covered from the bottom, and is never squeezed mid-animation.
        let clip = NSView(frame: NSRect(origin: .zero, size: panel.contentLayoutRect.size))
        clip.autoresizingMask = [.width, .height]
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        let content = controller.view
        content.autoresizingMask = [.width, .minYMargin]
        content.frame = NSRect(x: 0, y: clip.bounds.height - Self.hostHeight, width: clip.bounds.width, height: Self.hostHeight)
        clip.addSubview(content)
        clipView = clip

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: panel.contentLayoutRect)
            glass.cornerRadius = 18
            glass.contentView = clip
            panel.contentView = glass
        } else {
            let effect = NSVisualEffectView(frame: panel.contentLayoutRect)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 14
            effect.layer?.cornerCurve = .continuous
            effect.layer?.masksToBounds = true
            effect.addSubview(clip)
            panel.contentView = effect
        }

        self.hosting = controller
        self.panel = panel
        return panel
    }

    /// The size the panel's content wants right now, measured on a throwaway copy of the view.
    /// (The live hosting view is flexible so it can be pinned to the top, which means it cannot
    /// report its own ideal height, and it does not lay out while the panel is closed.)
    private func measuredSize() -> NSSize {
        let probe = NSHostingController(rootView: InverterPanel(store: store))
        let fitted = probe.sizeThatFits(in: CGSize(width: Self.panelWidth, height: 4000))
        return NSSize(width: Self.panelWidth, height: clampedHeight(fitted.height))
    }

    private func clampedHeight(_ wanted: CGFloat) -> CGFloat {
        min(max(wanted, 120), layout.maxHeight, Self.hostHeight).rounded(.up)
    }

    /// Pins the SwiftUI content to the top of the clip view at its fixed height.
    private func pinContent() {
        guard let clipView, let content = hosting?.view else { return }
        content.frame = NSRect(x: 0, y: clipView.bounds.height - Self.hostHeight,
                               width: clipView.bounds.width, height: Self.hostHeight)
    }

    /// SwiftUI reports a new content height once when a section opens or closes or a banner
    /// appears. Grow or shrink the window to match, pivoting on the top edge; the content
    /// underneath does not move, it is revealed or covered from the bottom.
    private func contentHeightChanged(_ reported: CGFloat) {
        let height = clampedHeight(reported)
        guard isOpen, let panel, abs(height - contentHeight) > 0.5 else { return }
        contentHeight = height
        let frame = NSRect(x: topLeft.x, y: topLeft.y - height, width: Self.panelWidth, height: height)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { panel.invalidateShadow() }
    }

    /// Where to hang the panel: under the status item, on the display that was clicked.
    /// macOS draws a copy of the item on every display but the app only knows the frame of one
    /// of them, so when the click landed on a different display the pointer's position stands in.
    private func anchorAndScreen() -> (NSRect, NSScreen) {
        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let eventType = NSApp.currentEvent?.type
        let clicked = eventType == .leftMouseDown || eventType == .rightMouseDown

        if let rect = statusItem.button?.window?.frame {
            let centre = NSPoint(x: rect.midX, y: rect.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: 0, dy: -2).contains(centre) }),
               !clicked || mouseScreen == nil || screen == mouseScreen {
                return (rect, screen)
            }
        }
        let screen = mouseScreen ?? NSScreen.main ?? NSScreen.screens[0]
        let bar = Self.menuBarHeight(on: screen, itemHeight: statusItem.button?.window?.frame.height ?? 0)
        return (NSRect(x: mouse.x - 14, y: screen.frame.maxY - bar, width: 28, height: bar), screen)
    }

    /// The menu bar's height on a display. `NSStatusBar.system.thickness` is the classic 22 pt
    /// and under-reports on current systems and notched displays, so take the largest of what
    /// the system offers, including the height of the status item's own window.
    private static func menuBarHeight(on screen: NSScreen, itemHeight: CGFloat) -> CGFloat {
        max(NSStatusBar.system.thickness, screen.safeAreaInsets.top,
            screen.frame.maxY - screen.visibleFrame.maxY, min(itemHeight, 44))
    }

    // MARK: Dismissal

    private func installMonitors() {
        // Global monitors only see events headed for other apps, so this fires for clicks outside
        // the panel and never for clicks in it (or in its menus).
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.staysOpen, self.isOpen else { return }
                self.closedByOutsideClickAt = Date()
                self.close()
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {   // Escape
                MainActor.assumeIsolated { self?.close() }
                return nil
            }
            return event
        }
        // Switching space, or switching app from the keyboard, would otherwise leave the panel
        // floating above everything with no click to dismiss it.
        let center = NSWorkspace.shared.notificationCenter
        let ownPID = ProcessInfo.processInfo.processIdentifier
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.staysOpen else { return }
                    self.close()
                }
            },
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let activated = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated {
                    guard let self, !self.staysOpen, activated != ownPID else { return }
                    self.close()
                }
            },
        ]
    }

    private func removeMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        outsideClickMonitor = nil
        keyMonitor = nil
        workspaceObservers = []
    }
}

/// How tall the panel may be on the display it is open on.
@MainActor
final class PanelLayout: ObservableObject {
    @Published var maxHeight: CGFloat = 1400
}

/// The panel's content, held to the top of whatever height it is given (without this SwiftUI
/// centres it when the hosting view is taller), reporting the height it wants, and scrolling
/// only when that is more than the display can show.
struct PanelRoot: View {
    @ObservedObject var store: AppStore
    @ObservedObject var layout: PanelLayout
    let onHeight: @MainActor (CGFloat) -> Void
    @State private var wanted: CGFloat = 0

    init(store: AppStore, layout: PanelLayout, onHeight: @escaping @MainActor (CGFloat) -> Void) {
        self.store = store
        self.layout = layout
        self.onHeight = onHeight
    }

    var body: some View {
        Group {
            if wanted > layout.maxHeight + 0.5 {
                ScrollView(.vertical) { measured }
                    .frame(height: layout.maxHeight)
            } else {
                measured
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // Height changes are animated here, at the very root. Animating only the card would
        // let its frame jump to the new height while its contents were still moving, and
        // SwiftUI would centre the contents in that frame for the length of the animation.
        .animation(.snappy, value: store.showToday)
        .animation(.snappy, value: store.showDetails)
        .animation(.snappy, value: bannerSignature)
    }

    private var measured: some View {
        InverterPanel(store: store)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height)
            })
            .onPreferenceChange(PanelHeightKey.self) { height in
                Task { @MainActor in
                    wanted = height
                    onHeight(height)
                }
            }
    }

    /// Changes whenever a banner appears or disappears, or the panel moves between its
    /// connecting, failed and live layouts.
    private var bannerSignature: String {
        let snapshot = store.snapshot
        return [snapshot == nil ? "none" : "live", store.errorMessage == nil ? "ok" : "error",
                snapshot?.activeWarning ?? "", (snapshot?.isStale() ?? false) ? "stale" : "fresh"].joined(separator: "|")
    }
}

private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A borderless panel does not take keyboard focus by default; this one does, so Escape closes it.
final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
