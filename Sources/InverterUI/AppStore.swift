import SwiftUI
import Combine
import InverterCore

/// What the menu bar shows beside the icon.
public enum MenuBarMetric: String, CaseIterable, Identifiable, Sendable {
    case battery, load, solar, none
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .battery: "Battery percent"
        case .load: "Load"
        case .solar: "Solar"
        case .none: "Icon only"
        }
    }
}

/// Holds the latest reading and the user's display choices, and polls the provider.
@MainActor
public final class AppStore: ObservableObject {
    @Published public private(set) var snapshot: EnergySnapshot?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var busy = false
    @Published public private(set) var today: DayCurve?
    @Published public private(set) var todayLoading = false
    @Published public private(set) var todayError: String?
    /// Frame of the menu bar icon's animation. Deliberately not `@Published`: a change here must
    /// redraw the status item only, not re-evaluate the whole panel.
    public private(set) var iconPhase = 0 { didSet { if iconPhase != oldValue { iconPhaseChanged.send() } } }
    public let iconPhaseChanged = PassthroughSubject<Void, Never>()

    @Published public var heroStyle: HeroStyle { didSet { if remembersHeroStyle { defaults.set(heroStyle.rawValue, forKey: Keys.hero) } } }
    @Published public var metric: MenuBarMetric { didSet { defaults.set(metric.rawValue, forKey: Keys.metric) } }
    @Published public var animateIcon: Bool { didSet { defaults.set(animateIcon, forKey: Keys.animate); if !animateIcon { stopIconBurst() } } }
    /// The two sections that open in place. Not remembered between launches.
    @Published public var showToday = false
    @Published public var showDetails = false
    @Published public var panelOpen = false { didSet { if panelOpen && !oldValue { panelOpened() } } }

    public let isDemo: Bool
    /// False when the illustration was forced for this run (`--style`), so that a recording
    /// does not overwrite the choice saved from the options menu.
    private let remembersHeroStyle: Bool
    private let provider: SnapshotProviding
    private let defaults: UserDefaults
    private var pollTask: Task<Void, Never>?
    private var iconTimer: Timer?
    private var lastAttempt = Date.distantPast
    private var consecutiveFailures = 0
    private var todayFetchedAt = Date.distantPast

    private enum Keys { static let hero = "heroStyle", metric = "menuBarMetric", animate = "animateIcon" }

    public init(provider: SnapshotProviding, isDemo: Bool = false, defaults: UserDefaults = .standard,
                heroStyle forced: HeroStyle? = nil) {
        self.provider = provider
        self.isDemo = isDemo
        self.defaults = defaults
        remembersHeroStyle = forced == nil
        heroStyle = forced ?? HeroStyle(rawValue: defaults.string(forKey: Keys.hero) ?? "") ?? HeroStyle.preferred
        metric = MenuBarMetric(rawValue: defaults.string(forKey: Keys.metric) ?? "") ?? .battery
        animateIcon = defaults.object(forKey: Keys.animate) as? Bool ?? true
    }

    /// A store frozen on one reading, for previews and lab renders. It never polls.
    public convenience init(preview snapshot: EnergySnapshot?, today: DayCurve? = nil, error: String? = nil) {
        self.init(provider: StaticProvider(snapshot: snapshot, today: today), isDemo: true, defaults: UserDefaults(suiteName: "InverterBar.preview") ?? .standard)
        self.snapshot = snapshot
        self.today = today
        self.errorMessage = error
    }

    public func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(force: false)
                // Sleep in short steps so that opening or closing the panel changes the cadence
                // straight away instead of after the current wait.
                while !Task.isCancelled, let self, Date().timeIntervalSince(self.lastAttempt) < self.pollInterval {
                    try? await Task.sleep(for: .seconds(self.isDemo ? 1 : 5))
                }
                if self == nil { return }
            }
        }
    }

    /// The logger reports to the cloud about every five minutes, so polling faster buys nothing.
    /// After a failure the next try comes sooner once (a Mac that has just woken often has no
    /// network for a few seconds), then the normal cadence resumes.
    private var pollInterval: Double {
        if isDemo { return 6 }
        if consecutiveFailures == 1 { return 15 }
        return panelOpen ? 60 : 150
    }

    public func refresh(force: Bool) async {
        guard !busy else { return }
        busy = true
        lastAttempt = Date()
        defer { busy = false }
        do {
            let reading = try await provider.fetchSnapshot(force: force)
            let isNew = reading != snapshot
            snapshot = reading
            errorMessage = nil
            consecutiveFailures = 0
            if isNew { startIconBurst() }
            if panelOpen && showToday { await loadToday() }
        } catch {
            errorMessage = Self.describe(error)
            consecutiveFailures += 1
        }
    }

    public func loadToday(force: Bool = false) async {
        guard !todayLoading, force || today == nil || Date().timeIntervalSince(todayFetchedAt) > 300 else { return }
        todayLoading = true
        defer { todayLoading = false }
        do {
            today = try await provider.fetchToday()
            todayFetchedAt = Date()
            todayError = nil
        } catch {
            todayError = Self.describe(error)
        }
    }

    private func panelOpened() {
        Task {
            if Date().timeIntervalSince(lastAttempt) > 30 { await refresh(force: false) }
            // The chart is otherwise only loaded when its section is toggled, so one left open
            // would show this morning's curve all day.
            if showToday { await loadToday() }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost: return "No internet connection."
            case .timedOut: return "The inverter cloud took too long to answer."
            default: return "Could not reach the inverter cloud."
            }
        }
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        // A file in Documents, Desktop or Downloads that macOS has not let the app into looks
        // exactly like a missing file, so say what to check.
        if let config = error as? InverterConfigError {
            let path: String
            switch config {
            case .fileNotFound(let p), .unreadable(let p): path = p
            case .missingKeys: return text
            }
            let home = NSHomeDirectory()
            if ["Documents", "Desktop", "Downloads"].contains(where: { path.hasPrefix("\(home)/\($0)/") }) {
                return text + " If the file is there, macOS may not have let InverterBar into that folder: "
                    + "allow it in System Settings, Privacy & Security, Files and Folders, then try again."
            }
        }
        return text
    }

    // MARK: Menu bar

    /// True when there is no reading, or the last one is too old to present as current: the
    /// logger has been silent for 15 minutes, or nothing has been fetched for 10.
    public var readingIsStale: Bool {
        guard let snapshot else { return true }
        if isDemo { return false }
        return snapshot.isStale() || Date().timeIntervalSince(snapshot.fetchedAt) > 600
    }

    /// The number beside the icon. Nothing is shown for a stale reading: an old percentage that
    /// looks live is worse than none.
    public var menuBarText: String? {
        guard let snapshot, !readingIsStale else { return nil }
        switch metric {
        case .battery: return snapshot.batteryPercent.map { "\(Int($0.rounded()))%" }
        case .load: return PowerFormat.watts(snapshot.loadPowerW)
        case .solar: return PowerFormat.watts(snapshot.pvPowerW)
        case .none: return nil
        }
    }

    /// The icon moves for a few seconds when a new reading arrives and then rests. Redrawing a
    /// status item is not free (macOS re-renders it for every display), so a permanent animation
    /// would cost a few percent of a core all day for something nobody is watching.
    private static let burstTicks = 9

    private func startIconBurst() {
        let moving = animateIcon && (abs(snapshot?.batteryPowerW ?? 0) > 30 || (snapshot?.pvPowerW ?? 0) > 20)
        guard moving else { stopIconBurst(); return }
        iconTimer?.invalidate()
        var remaining = Self.burstTicks
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                remaining -= 1
                if remaining <= 0 {
                    self.stopIconBurst()
                } else {
                    self.iconPhase = (self.iconPhase + 1) % MenuBarIcon.phases
                }
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        iconTimer = timer
    }

    private func stopIconBurst() {
        iconTimer?.invalidate()
        iconTimer = nil
        iconPhase = 0
    }
}

private struct StaticProvider: SnapshotProviding {
    let snapshot: EnergySnapshot?
    let today: DayCurve?
    func fetchSnapshot(force: Bool) async throws -> EnergySnapshot { snapshot ?? EnergySnapshot() }
    func fetchToday() async throws -> DayCurve { today ?? DayCurve(day: "", dayStart: Date()) }
}

/// Walks through the fixed scenarios so every animation and transition can be seen without the inverter.
public actor DemoProvider: SnapshotProviding {
    private var index = -1
    public init() {}

    public func fetchSnapshot(force: Bool) async throws -> EnergySnapshot {
        let scenarios = HeroScenario.all.filter { $0.snapshot != nil }
        index = (index + 1) % scenarios.count
        var reading = scenarios[index].snapshot ?? EnergySnapshot()
        reading.fetchedAt = Date()
        reading.deviceTime = Date().addingTimeInterval(-45)
        return reading
    }

    public func fetchToday() async throws -> DayCurve { Self.sampleDay(until: Date()) }

    /// A plausible clear day: a solar bell around 12:30 and a daytime-heavy load.
    public static func sampleDay(until end: Date, calendar: Calendar = .current) -> DayCurve {
        let start = calendar.startOfDay(for: end)
        var points: [DayCurvePoint] = []
        var t = start
        var step = 0
        while t <= end {
            let hour = t.timeIntervalSince(start) / 3600
            let sun = max(0, sin((hour - 6.2) / 12.4 * .pi))
            // Slow drift (passing cloud, appliances cycling) rather than sample-to-sample noise.
            let drift = 0.5 + 0.5 * sin(Double(step) * 0.11) * cos(Double(step) * 0.037)
            let pv = hour > 6.2 && hour < 18.6 ? 4200 * pow(sun, 1.4) * (0.86 + 0.14 * drift) : 0
            let load = 650 + 1500 * max(0, sin((hour - 8) / 11 * .pi)) + 320 * drift + (hour > 19 && hour < 23 ? 500 : 0)
            let battery = min(100, max(18, 52 + 40 * sin((hour - 9) / 14 * .pi)))
            points.append(DayCurvePoint(time: t, pvW: pv, loadW: load, batteryPercent: battery))
            t = t.addingTimeInterval(300)
            step += 1
        }
        let name = DateFormatter()
        name.calendar = calendar
        name.timeZone = calendar.timeZone
        name.dateFormat = "yyyy-MM-dd"
        return DayCurve(day: name.string(from: start), dayStart: start, points: points, fetchedAt: end)
    }
}
