import SwiftUI
import Combine
import InverterCore

/// What the menu bar shows beside the icon.
public enum MenuBarMetric: String, CaseIterable, Identifiable, Sendable {
    case battery, load, solar, solarAndGrid, none
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .battery: "Battery percent"
        case .load: "Load"
        case .solar: "Solar"
        case .solarAndGrid: "Solar and grid"
        case .none: "Icon only"
        }
    }
    /// SF Symbol shown beside the title in the options menu.
    public var symbol: String {
        switch self {
        case .battery: "battery.75percent"
        case .load: "house"
        case .solar: "sun.max"
        case .solarAndGrid: "sun.max.circle"
        case .none: "menubar.rectangle"
        }
    }

    /// What the menu bar shows for a reading: one symbol and number per value, following the
    /// reading (the battery at its level with a bolt while charging, a sun for solar that turns to a
    /// moon when the panels make nothing). Empty for the icon alone.
    public func segments(for reading: EnergySnapshot) -> [(symbol: String, text: String)] {
        let solar = (Self.solarSymbol(reading), PowerFormat.watts(reading.pvPowerW))
        switch self {
        case .battery:
            guard let percent = reading.batteryPercent else { return [] }
            return [(reading.batteryPowerW > 30 ? "battery.100percent.bolt" : Self.batterySymbol(percent), "\(Int(percent.rounded()))%")]
        case .load: return [("house", PowerFormat.watts(reading.loadPowerW))]
        case .solar: return [solar]
        case .solarAndGrid: return [solar, (Self.gridSymbol(reading), PowerFormat.watts(reading.gridPowerW))]
        case .none: return []
        }
    }

    public static func solarSymbol(_ reading: EnergySnapshot) -> String { reading.pvPowerW > 20 ? "sun.max" : "moon" }
    public static func gridSymbol(_ reading: EnergySnapshot) -> String { reading.gridPresent ? "powerplug" : "bolt.slash" }

    public static func batterySymbol(_ percent: Double?) -> String {
        guard let percent else { return "battery.0percent" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// Which list the History section shows.
public enum HistoryTab: String, CaseIterable, Identifiable, Sendable {
    case days = "Days", months = "Months"
    public var id: String { rawValue }
}

/// Holds the latest reading and the user's display choices, and polls the provider.
@MainActor
public final class AppStore: ObservableObject {
    @Published public private(set) var snapshot: EnergySnapshot?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var busy = false
    /// True when the account file is missing or incomplete, or the cloud refused the login.
    @Published public private(set) var signInRequired = false
    @Published public private(set) var signInError: String?
    @Published public private(set) var today: DayCurve?
    @Published public private(set) var todayLoading = false
    @Published public private(set) var todayError: String?
    /// Daily totals read so far, by day ("2026-10-13").
    @Published public private(set) var history: [String: DayTotals] = [:]
    @Published public private(set) var historyLoading = false
    @Published public private(set) var historyError: String?
    /// The inverters on the account; more than one means the panel offers a switcher.
    @Published public private(set) var devices: [DeviceInfo] = []
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
    @Published public var showHistory = false
    @Published public var historyTab: HistoryTab = .days { didSet { if historyTab != oldValue { Task { await loadHistory() } } } }
    @Published public var panelOpen = false { didSet { if panelOpen && !oldValue { panelOpened() } } }

    /// False when the illustration was forced for this run (`--style`), so that the run does not
    /// overwrite the choice saved from the options menu.
    private let remembersHeroStyle: Bool
    private let provider: SnapshotProviding
    private let defaults: UserDefaults
    private var pollTask: Task<Void, Never>?
    private var iconTimer: Timer?
    private var lastAttempt = Date.distantPast
    private var consecutiveFailures = 0
    private var todayFetchedAt = Date.distantPast
    private var historyFetchedAt = Date.distantPast

    private enum Keys { static let hero = "heroStyle", metric = "menuBarMetric", animate = "animateIcon", device = "inverterSN" }

    public init(provider: SnapshotProviding, defaults: UserDefaults = .standard,
                heroStyle forced: HeroStyle? = nil) {
        self.provider = provider
        self.defaults = defaults
        remembersHeroStyle = forced == nil
        heroStyle = forced ?? HeroStyle(rawValue: defaults.string(forKey: Keys.hero) ?? "") ?? HeroStyle.preferred
        metric = MenuBarMetric(rawValue: defaults.string(forKey: Keys.metric) ?? "") ?? .battery
        animateIcon = defaults.object(forKey: Keys.animate) as? Bool ?? true
    }

    public func start() {
        guard pollTask == nil else { return }
        let savedDevice = defaults.string(forKey: Keys.device)
        pollTask = Task { [weak self] in
            if let savedDevice { await self?.provider.selectDevice(savedDevice) }
            while !Task.isCancelled {
                await self?.refresh(force: false)
                // Sleep in short steps so that opening or closing the panel changes the cadence
                // straight away instead of after the current wait.
                while !Task.isCancelled, let self, Date().timeIntervalSince(self.lastAttempt) < self.pollInterval {
                    try? await Task.sleep(for: .seconds(5))
                }
                if self == nil { return }
            }
        }
    }

    /// The logger reports to the cloud about every five minutes, so polling faster buys nothing.
    /// After a failure the next try comes sooner once (a Mac that has just woken often has no
    /// network for a few seconds), then the normal cadence resumes.
    private var pollInterval: Double {
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
            signInRequired = false
            consecutiveFailures = 0
            if isNew { startIconBurst() }
            if devices.isEmpty { Task { await loadDevices() } }
            if panelOpen && showToday { await loadToday() }
        } catch {
            errorMessage = Self.describe(error)
            signInRequired = Self.needsSignIn(error)
            consecutiveFailures += 1
        }
    }

    /// Saves the account, then reads the inverter with it, trying each app profile. A failure is left in `signInError`.
    public func signIn(user: String, password: String) async {
        signInError = nil
        // The three phone apps share one login but sign it with different app identities, and the
        // cloud answers a wrong identity the same way as a wrong password. So try each in turn; the
        // first one the cloud accepts is saved. Only a refused login moves on to the next.
        for profile in CloudProfile.all {
            do {
                try InverterConfig.save(app: profile.name, user: user, password: password)
            } catch {
                signInError = "Could not save the account: \(error.localizedDescription)"
                return
            }
            await provider.reset()
            snapshot = nil
            await waitUntilIdle()
            await refresh(force: true)
            if snapshot != nil || !signInRequired { break }
        }
        if signInRequired || snapshot == nil { signInError = errorMessage ?? "Could not read the inverter." }
    }

    /// A refresh already running would land after a reset; let it finish first.
    private func waitUntilIdle() async {
        while busy { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// Drops everything read for the current inverter.
    private func clearReadings() {
        snapshot = nil; errorMessage = nil
        today = nil; todayError = nil; todayFetchedAt = .distantPast
        history = [:]; historyError = nil; historyFetchedAt = .distantPast
    }

    // MARK: Inverters

    /// The name of the inverter shown, when the account has more than one.
    public var selectedDeviceName: String? {
        devices.count > 1 ? devices.first(where: \.isSelected)?.name : nil
    }

    private func loadDevices() async {
        guard let found = try? await provider.listDevices(), !found.isEmpty else { return }
        devices = found
    }

    /// Shows another inverter. Its reading, chart and history replace the last one's.
    public func selectDevice(_ id: String) async {
        guard devices.contains(where: { $0.id == id }), !devices.contains(where: { $0.id == id && $0.isSelected }) else { return }
        defaults.set(id, forKey: Keys.device)
        devices = devices.map { DeviceInfo(id: $0.id, name: $0.name, isSelected: $0.id == id) }
        await provider.selectDevice(id)
        await waitUntilIdle()
        clearReadings()
        await refresh(force: true)
        if showToday { await loadToday(force: true) }
        if showHistory { await loadHistory(force: true) }
    }

    /// Forgets the account and its session and goes back to the sign-in form.
    public func signOut() async {
        do { try InverterConfig.signOut() } catch {
            errorMessage = "Could not remove the account: \(error.localizedDescription)"
            return
        }
        await provider.reset()
        await waitUntilIdle()
        clearReadings()
        devices = []
        defaults.removeObject(forKey: Keys.device)
        signInError = nil; signInRequired = true
        stopIconBurst()
    }

    private static func needsSignIn(_ error: Error) -> Bool {
        if error is InverterConfigError { return true }
        switch error as? DessMonitorError {
        case .missingCredentials, .loginRejected: return true
        default: return false
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

    // MARK: History

    /// The days of the current month that have been read, newest first.
    public var currentMonthDays: [DayTotals] {
        let month = SnapshotParser.dayString(for: Date(), in: .current).prefix(7)
        return history.values.filter { $0.day.hasPrefix(month) }.sorted { $0.day > $1.day }
    }

    /// Every month that has been read, newest first.
    public var months: [MonthTotals] { MonthTotals.monthly(history.values) }

    /// Reads the days of this month, and for the Months tab the months before it, until one has
    /// nothing. Finished days come from disk after the first time; only today is read again.
    public func loadHistory(force: Bool = false) async {
        guard !historyLoading, force || Date().timeIntervalSince(historyFetchedAt) > 300 else { return }
        historyLoading = true
        historyError = nil
        defer { historyLoading = false; historyFetchedAt = Date() }

        // Day keys are Gregorian, as the cloud's are, whatever calendar the Mac is set to.
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        var month = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
        let monthsToRead = historyTab == .days ? 1 : 24
        for index in 0..<monthsToRead {
            let days = Self.days(of: month, upTo: today, calendar: calendar)
            guard await readDays(days) || index == 0 else { break }
            guard let earlier = calendar.date(byAdding: .month, value: -1, to: month) else { break }
            month = earlier
        }
    }

    private static func days(of month: Date, upTo today: Date, calendar: Calendar) -> [String] {
        let count = calendar.range(of: .day, in: .month, for: month)?.count ?? 0
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: month) }
            .filter { $0 <= today }.map { SnapshotParser.dayString(for: $0, in: calendar.timeZone) }
    }

    /// Reads these days, three at a time, and publishes them together (one panel update, not one per day).
    /// True if any of them has data.
    private func readDays(_ days: [String]) async -> Bool {
        let provider = self.provider
        var pending = days.filter { history[$0]?.complete != true }.makeIterator()
        var read: [String: DayTotals] = [:]
        var failure: Error?
        await withTaskGroup(of: (String, DayTotals?, Error?).self) { group in
            for _ in 0..<3 {
                guard let day = pending.next() else { break }
                group.addTask { await Self.read(day, from: provider) }
            }
            while let (day, totals, error) = await group.next() {
                if let totals { read[day] = totals }
                if let error { failure = error }
                if let next = pending.next() { group.addTask { await Self.read(next, from: provider) } }
            }
        }
        if !read.isEmpty { history.merge(read) { $1 } }
        if let failure { historyError = Self.describe(failure) }
        return days.contains { history[$0] != nil }
    }

    private nonisolated static func read(_ day: String, from provider: SnapshotProviding) async -> (String, DayTotals?, Error?) {
        do { return (day, try await provider.fetchDayTotals(day: day), nil) } catch { return (day, nil, error) }
    }

    private func panelOpened() {
        Task {
            if Date().timeIntervalSince(lastAttempt) > 30 { await refresh(force: false) }
            // The chart is otherwise only loaded when its section is toggled, so one left open
            // would show this morning's curve all day.
            if showToday { await loadToday() }
            if showHistory { await loadHistory() }
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
                return text + " If the file is there, macOS may not have let Inverterly into that folder: "
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
        return snapshot.isStale() || Date().timeIntervalSince(snapshot.fetchedAt) > 600
    }

    /// The values beside the icon. Nothing is shown for a stale reading: an old percentage that
    /// looks live is worse than none.
    public var menuBarSegments: [(symbol: String, text: String)] {
        guard let snapshot, !readingIsStale else { return [] }
        return metric.segments(for: snapshot)
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
