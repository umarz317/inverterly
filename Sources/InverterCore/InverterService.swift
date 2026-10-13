import Foundation

/// What the UI needs from a data source. `InverterService` is the live one; a demo or preview
/// provider only has to return canned values.
public protocol SnapshotProviding: Sendable {
    /// The current reading. `force` skips the cache.
    func fetchSnapshot(force: Bool) async throws -> EnergySnapshot
    /// Today's readings for the small chart.
    func fetchToday() async throws -> DayCurve
}

public extension SnapshotProviding {
    func fetchSnapshot() async throws -> EnergySnapshot {
        try await fetchSnapshot(force: false)
    }
}

/// A provider that always answers with the values it was given. For previews, demos and tests.
public struct StaticSnapshotProvider: SnapshotProviding {
    public var snapshot: EnergySnapshot
    public var curve: DayCurve

    public init(snapshot: EnergySnapshot, curve: DayCurve? = nil) {
        self.snapshot = snapshot
        let zone = TimeZone.current
        let day = SnapshotParser.dayString(for: snapshot.fetchedAt, in: zone)
        self.curve = curve ?? DayCurve(day: day,
                                       dayStart: SnapshotParser.parseTimestamp("\(day) 00:00:00", in: zone) ?? snapshot.fetchedAt,
                                       fetchedAt: snapshot.fetchedAt)
    }

    public func fetchSnapshot(force: Bool) async throws -> EnergySnapshot { snapshot }
    public func fetchToday() async throws -> DayCurve { curve }
}

/// Live, READ-ONLY view of the inverter through the vendor cloud.
///
/// The actions it sends are all queries: `webQueryDeviceEs` / `queryDevices` (find the inverter),
/// `queryDeviceLastData` (the reading), `queryDeviceWarning`, `queryPlants`, `webQueryCollectorsEs`
/// and `queryDeviceDataOneDay`. There is no control action anywhere in this package.
public actor InverterService: SnapshotProviding {
    /// The logger only reports about every 5 minutes, so asking more often than this buys nothing.
    public static let snapshotLifetime: TimeInterval = 20
    public static let dayCurveLifetime: TimeInterval = 5 * 60
    static let plantLifetime: TimeInterval = 60 * 60

    private let envPath: String?
    private let sessionStore: SessionStore
    private let transport: (any HTTPTransport)?
    private let now: @Sendable () -> Date
    /// How long the side lookups (warning, logger status, plant) may run on after the reading
    /// itself has arrived before a snapshot is built without them.
    private var sideLookupGrace: TimeInterval = 2.5

    /// For tests.
    func setSideLookupGrace(_ seconds: TimeInterval) { sideLookupGrace = seconds }

    private var config: InverterConfig?
    private var client: DessMonitorClient?
    /// Found once and kept for the life of the process.
    private var device: DeviceRef?
    private var deviceTask: Task<DeviceRef, Error>?
    private var plant: (at: Date, info: PlantInfo)?
    private var plantTask: Task<PlantInfo?, Never>?

    private var snapshotCache: (at: Date, value: EnergySnapshot)?
    private var snapshotTask: Task<EnergySnapshot, Error>?
    private var curveCache: (at: Date, zone: TimeZone, value: DayCurve)?
    private var curveTask: Task<DayCurve, Error>?

    /// Reads the account from the env file on first use (see `InverterConfig.resolvePath`), so a
    /// missing file shows up as an error from `fetchSnapshot()` and is picked up once it exists.
    public init(envPath: String? = nil, sessionStore: SessionStore = .standard) {
        self.envPath = envPath
        self.sessionStore = sessionStore
        self.transport = nil
        self.now = { Date() }
    }

    /// As `init(envPath:sessionStore:)`, with the HTTP layer supplied by the caller: a recording
    /// transport for diagnostics, or a canned one for a demo. The read-only gate sits above the
    /// transport, so it applies all the same.
    public init(envPath: String? = nil, sessionStore: SessionStore = .standard, transport: any HTTPTransport) {
        self.envPath = envPath
        self.sessionStore = sessionStore
        self.transport = transport
        self.now = { Date() }
    }

    public init(config: InverterConfig, sessionStore: SessionStore = .standard) {
        self.envPath = nil
        self.config = config
        self.sessionStore = sessionStore
        self.transport = nil
        self.now = { Date() }
    }

    /// For tests: a canned transport and a controllable clock.
    init(config: InverterConfig, sessionStore: SessionStore, transport: any HTTPTransport,
         now: @escaping @Sendable () -> Date) {
        self.envPath = nil
        self.config = config
        self.sessionStore = sessionStore
        self.transport = transport
        self.now = now
    }

    // MARK: Last good values

    /// The most recent good reading, however old; nil before the first one. A refresh that fails
    /// does not clear it, so the panel can keep showing it beside the error. Never touches the network.
    public var lastSnapshot: EnergySnapshot? { snapshotCache?.value }

    /// The most recent good day curve, however old; nil before the first one.
    public var lastToday: DayCurve? { curveCache?.value }

    // MARK: Snapshot

    /// One reading of the inverter. Answers from a 20 s cache unless `force` is set, and callers
    /// that arrive while a fetch is running share that fetch.
    ///
    /// The reading itself must succeed. The plant name, the active warning and the logger status
    /// are fetched alongside and simply stay nil if their calls fail.
    public func fetchSnapshot(force: Bool = false) async throws -> EnergySnapshot {
        if !force, let cached = snapshotCache, now().timeIntervalSince(cached.at) < Self.snapshotLifetime {
            return cached.value
        }
        if let snapshotTask { return try await snapshotTask.value }
        let task = Task { try await self.loadSnapshot() }
        snapshotTask = task
        defer { snapshotTask = nil }
        return try await task.value
    }

    private func loadSnapshot() async throws -> EnergySnapshot {
        let client = try loadClient()
        let device = try await loadDevice(client)
        let query = device.query

        // The reading is what the panel is waiting for. The three side lookups run alongside it
        // and get a short grace once it has landed; one that is still out by then is left out of
        // this snapshot instead of holding it up. (One stalled connection used to cost the whole
        // 20 s timeout before anything was shown.)
        let warningsTask = Task { await Self.tolerating { try await client.request("queryDeviceWarning&\(query)&i18n=en_US&page=0&pagesize=50") } }
        let collectorsTask = Task { await Self.tolerating { try await client.request("webQueryCollectorsEs&page=0&pagesize=50") } }
        let plantTask = Task { await self.loadPlant(client, preferID: device.plantID) }

        let reading: JSONValue
        do {
            reading = try await client.request("queryDeviceLastData&\(query)&i18n=en_US")
        } catch {
            warningsTask.cancel()
            collectorsTask.cancel()
            plantTask.cancel()
            // If the cloud no longer knows this device (re-bound stick, new device code), look it
            // up again next time instead of repeating a query that cannot work.
            if let refusal = error as? DessMonitorError, case .api = refusal, !refusal.isAuthFailure {
                self.device = nil
            }
            throw error
        }

        let deadline = ContinuousClock.now + .seconds(sideLookupGrace)
        let warnings = await Self.value(of: warningsTask, by: deadline)
        let collectors = await Self.value(of: collectorsTask, by: deadline)
        // A plant lookup that is late still finishes and is cached for the next reading.
        let plantInfo = await Self.value(of: plantTask, by: deadline) ?? plant?.info

        let fetchedAt = now()
        let snapshot = try SnapshotParser.snapshot(lastData: reading,
                                                   warnings: warnings,
                                                   plant: plantInfo,
                                                   collectors: collectors,
                                                   device: device,
                                                   fetchedAt: fetchedAt)
        snapshotCache = (fetchedAt, snapshot)
        return snapshot
    }

    // MARK: Day curve

    /// Today's logger reports (one about every 5 minutes) as chart points. Cached for 5 minutes,
    /// and dropped when the plant's calendar day rolls over.
    public func fetchToday() async throws -> DayCurve {
        if let cached = curveCache, now().timeIntervalSince(cached.at) < Self.dayCurveLifetime,
           cached.value.day == SnapshotParser.dayString(for: now(), in: cached.zone) {
            return cached.value
        }
        if let curveTask { return try await curveTask.value }
        let task = Task { try await self.loadToday() }
        curveTask = task
        defer { curveTask = nil }
        return try await task.value
    }

    private func loadToday() async throws -> DayCurve {
        let client = try loadClient()
        let device = try await loadDevice(client)
        let plantTask = Task { await self.loadPlant(client, preferID: device.plantID) }
        let plantInfo = await Self.value(of: plantTask, by: ContinuousClock.now + .seconds(sideLookupGrace)) ?? plant?.info
        let zone = plantInfo?.timeZone ?? device.timeZone ?? .current
        let fetchedAt = now()
        let day = SnapshotParser.dayString(for: fetchedAt, in: zone)

        let curve: DayCurve
        do {
            let dat = try await client.request("queryDeviceDataOneDay&\(device.query)&date=\(day)&i18n=en_US")
            curve = try SnapshotParser.dayCurve(dat, day: day, timeZone: zone, fetchedAt: fetchedAt)
        } catch let error as DessMonitorError where error.isNoRecord {
            // Just after midnight there is nothing stored for the new day yet. That is an empty chart, not a failure.
            curve = try SnapshotParser.dayCurve(.null, day: day, timeZone: zone, fetchedAt: fetchedAt)
        }
        curveCache = (fetchedAt, zone, curve)
        return curve
    }

    // MARK: Shared lookups

    private func loadClient() throws -> DessMonitorClient {
        if let client { return client }
        let config = try self.config ?? InverterConfig.load(path: envPath)
        self.config = config
        let made: DessMonitorClient
        if let transport {
            made = DessMonitorClient(config: config, sessionStore: sessionStore, transport: transport, now: now)
        } else {
            made = DessMonitorClient(config: config, sessionStore: sessionStore, now: now)
        }
        client = made
        return made
    }

    /// The inverter to ask about. Found once per process; the snapshot and the day curve share
    /// the lookup when they start together.
    private func loadDevice(_ client: DessMonitorClient) async throws -> DeviceRef {
        if let device { return device }
        if let deviceTask { return try await deviceTask.value }
        let task = Task { try await self.discoverDevice(client) }
        deviceTask = task
        defer { deviceTask = nil }
        return try await task.value
    }

    /// `webQueryDeviceEs` first, `queryDevices` if that fails, as in the Node client.
    private func discoverDevice(_ client: DessMonitorClient) async throws -> DeviceRef {
        let listing: JSONValue
        do {
            listing = try await client.request("webQueryDeviceEs")
        } catch let first {
            guard Self.secondListMayHelp(after: first),
                  let fallback = try? await client.request("queryDevices&page=0&pagesize=50&i18n=en_US") else { throw first }
            listing = fallback
        }
        guard let found = SnapshotParser.pickDevice(from: listing, preferPN: config?.collectorPN, preferSN: config?.inverterSN),
              found.isQueryable else {
            throw InverterDataError.noDevice
        }
        device = found
        return found
    }

    /// The Node client tries the second list after any failure. Here it is skipped when it cannot
    /// succeed either (no connection, login refused, fetch cancelled), so the real error reaches
    /// the user at once instead of after a second wait.
    private static func secondListMayHelp(after error: Error) -> Bool {
        guard let error = error as? DessMonitorError else { return false }
        switch error {
        case .api: return !error.isAuthFailure
        case .badResponse, .timedOut, .network: return true
        case .offline, .loginRejected, .missingCredentials, .invalidRequest, .actionNotAllowed: return false
        }
    }

    /// The plant gives the display name and the time zone the logger's timestamps are in. It
    /// rarely changes, so it is asked for at most once an hour; a failed refresh keeps the old answer.
    private func loadPlant(_ client: DessMonitorClient, preferID: Int?) async -> PlantInfo? {
        if let plant, now().timeIntervalSince(plant.at) < Self.plantLifetime { return plant.info }
        if let plantTask { return await plantTask.value }
        let task = Task { await self.refreshPlant(client, preferID: preferID) }
        plantTask = task
        defer { plantTask = nil }
        return await task.value
    }

    private func refreshPlant(_ client: DessMonitorClient, preferID: Int?) async -> PlantInfo? {
        guard let dat = try? await client.request("queryPlants&page=0&pagesize=20&i18n=en_US"),
              let info = SnapshotParser.plant(in: dat, preferID: preferID) else {
            return plant?.info
        }
        plant = (now(), info)
        return info
    }

    /// Runs a side lookup whose failure must not fail the reading.
    private static func tolerating<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> T? {
        try? await operation()
    }

    /// The task's value if it is ready by `deadline`, otherwise nil, without waiting any longer.
    /// The late task is cancelled; a lookup shared with other callers carries on underneath.
    private static func value<T: Sendable>(of task: Task<T?, Never>, by deadline: ContinuousClock.Instant) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let winner = FirstClaim()
            Task {
                let value = await task.value
                if winner.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(until: deadline, clock: .continuous)
                if winner.claim() {
                    task.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

/// Lets exactly one of several racing tasks go first.
private final class FirstClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
