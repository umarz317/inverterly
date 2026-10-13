import XCTest
@testable import InverterCore

/// The whole read path (login, device discovery, reading, side lookups, caches) against the fake cloud.
final class ServiceTests: ScratchTestCase {
    private var clock: TestClock!
    private var cloud: FakeCloud!
    private var service: InverterService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        clock = TestClock()
        cloud = FakeCloud.withFixtures(config: TestAccount.config)
        service = makeService()
    }

    private func makeService(_ config: InverterConfig = TestAccount.config) -> InverterService {
        InverterService(config: config, sessionStore: store, transport: cloud, now: clock.reader)
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    // MARK: Snapshot

    func testSnapshotFromTheCapturedPayloads() async throws {
        let s = try await service.fetchSnapshot()
        XCTAssertEqual(s.fetchedAt, clock.now)
        XCTAssertEqual(s.deviceTime, date("2026-10-13T12:22:30Z"))
        XCTAssertEqual(s.pvPowerW, 19)
        XCTAssertEqual(s.loadPowerW, 1154)
        XCTAssertEqual(s.batteryPercent, 86)
        XCTAssertEqual(s.batteryDischargeA, 21)
        XCTAssertEqual(s.gridVoltage, 233.3)
        XCTAssertEqual(s.ratedPowerW, 6000)
        XCTAssertEqual(try XCTUnwrap(s.todayKWh), 22.985, accuracy: 1e-9)
        XCTAssertEqual(s.plantName, "PLANT")
        XCTAssertEqual(s.machineType, "Off Grid Tie")
        XCTAssertEqual(s.collectorOnline, true)
        XCTAssertNil(s.activeWarning)
        XCTAssertEqual(s.mode, .battery)

        XCTAssertEqual(cloud.logins, 1)
        XCTAssertEqual(cloud.signatureFailures, [])
        XCTAssertEqual(cloud.last("queryDeviceLastData")?.query,
                       "queryDeviceLastData&pn=W0000000000000&devcode=2452&devaddr=1&sn=00000000000000&i18n=en_US",
                       "same parameter order as the Node client")
        XCTAssertEqual(cloud.last("queryDeviceWarning")?.query,
                       "queryDeviceWarning&pn=W0000000000000&devcode=2452&devaddr=1&sn=00000000000000&i18n=en_US&page=0&pagesize=50")
        XCTAssertEqual(cloud.last("queryPlants")?.query, "queryPlants&page=0&pagesize=20&i18n=en_US")
        XCTAssertEqual(cloud.last("webQueryCollectorsEs")?.query, "webQueryCollectorsEs&page=0&pagesize=50")
    }

    func testOnlyReadActionsAreEverSent() async throws {
        _ = try await service.fetchSnapshot()
        _ = try await service.fetchToday()
        let allowed: Set<String> = ["authSource", "webQueryDeviceEs", "queryDevices", "queryDeviceLastData", "queryDeviceWarning",
                                    "queryPlants", "webQueryCollectorsEs", "queryDeviceDataOneDay"]
        for call in cloud.calls {
            XCTAssertTrue(allowed.contains(call.action), "unexpected action \(call.action)")
            XCTAssertFalse(call.action.lowercased().contains("ctrl"), "nothing that could change a setting")
        }
    }

    func testSnapshotIsCachedForTwentySeconds() async throws {
        let first = try await service.fetchSnapshot()
        XCTAssertEqual(cloud.count("queryDeviceLastData"), 1)

        clock.advance(19)
        let second = try await service.fetchSnapshot()
        XCTAssertEqual(second, first)
        XCTAssertEqual(cloud.count("queryDeviceLastData"), 1, "inside 20 s: answered from the cache")

        clock.advance(2)
        let third = try await service.fetchSnapshot()
        XCTAssertEqual(cloud.count("queryDeviceLastData"), 2, "after 20 s: fetched again")
        XCTAssertEqual(third.fetchedAt, clock.now)
        XCTAssertEqual(cloud.count("queryDeviceWarning"), 2)
        XCTAssertEqual(cloud.count("webQueryCollectorsEs"), 2)
    }

    func testForceSkipsTheCache() async throws {
        _ = try await service.fetchSnapshot()
        _ = try await service.fetchSnapshot(force: true)
        XCTAssertEqual(cloud.count("queryDeviceLastData"), 2)
        _ = try await service.fetchSnapshot(force: false)
        XCTAssertEqual(cloud.count("queryDeviceLastData"), 2, "the forced reading refreshed the cache")
    }

    func testDeviceDiscoveryAndLoginHappenOnce() async throws {
        for _ in 0..<5 {
            _ = try await service.fetchSnapshot(force: true)
            clock.advance(30)
        }
        XCTAssertEqual(cloud.count("queryDeviceLastData"), 5)
        XCTAssertEqual(cloud.count("webQueryDeviceEs"), 1, "the device is found once per process")
        XCTAssertEqual(cloud.count("queryDevices"), 0)
        XCTAssertEqual(cloud.count("queryPlants"), 1, "the plant is asked for at most once an hour")
        XCTAssertEqual(cloud.logins, 1)

        clock.advance(3600)
        _ = try await service.fetchSnapshot(force: true)
        XCTAssertEqual(cloud.count("queryPlants"), 2)
        XCTAssertEqual(cloud.count("webQueryDeviceEs"), 1)
    }

    func testCallersThatArriveTogetherShareOneFetch() async throws {
        let service = self.service!
        let snapshots = try await withThrowingTaskGroup(of: EnergySnapshot.self) { group in
            for _ in 0..<6 {
                group.addTask { try await service.fetchSnapshot(force: true) }
            }
            var all: [EnergySnapshot] = []
            for try await snapshot in group { all.append(snapshot) }
            return all
        }
        XCTAssertEqual(snapshots.count, 6)
        XCTAssertEqual(Set(snapshots.map(\.loadPowerW)), [1154])
        XCTAssertEqual(cloud.count("webQueryDeviceEs"), 1)
        XCTAssertLessThanOrEqual(cloud.count("queryDeviceLastData"), 2, "six callers do not mean six requests")
        XCTAssertEqual(cloud.logins, 1)
    }

    func testSnapshotAndCurveStartedTogetherShareLoginDeviceAndPlant() async throws {
        let service = self.service!
        async let snapshot = service.fetchSnapshot()
        async let curve = service.fetchToday()
        let (s, c) = try await (snapshot, curve)
        XCTAssertEqual(s.loadPowerW, 1154)
        XCTAssertEqual(c.points.count, 9)
        XCTAssertEqual(cloud.logins, 1)
        XCTAssertEqual(cloud.count("webQueryDeviceEs"), 1)
        XCTAssertEqual(cloud.count("queryPlants"), 1)
        XCTAssertEqual(cloud.calls.count, 7, "login, device list, reading, warnings, collectors, plant, day")
    }

    func testSideLookupsMayFailWithoutFailingTheSnapshot() async throws {
        cloud.fail("queryDeviceWarning", code: 1, desc: "ERR_FAIL")
        cloud.breakTransport("queryPlants", with: URLError(.timedOut))
        cloud.respond("webQueryCollectorsEs", body: Data("not json".utf8))

        let s = try await service.fetchSnapshot()
        XCTAssertEqual(s.loadPowerW, 1154)
        XCTAssertEqual(s.batteryVoltage, 52.7)
        XCTAssertNil(s.activeWarning)
        XCTAssertNil(s.plantName)
        XCTAssertNil(s.collectorOnline)
        XCTAssertNotNil(s.deviceTime, "falls back to this Mac's time zone")

        // The lookups recover on their own once the cloud does.
        cloud.respond("queryPlants", dat: Fixtures.plants)
        cloud.respond("webQueryCollectorsEs", dat: Fixtures.collectors)
        clock.advance(21)
        let later = try await service.fetchSnapshot()
        XCTAssertEqual(later.plantName, "PLANT")
        XCTAssertEqual(later.collectorOnline, true)
        XCTAssertEqual(later.deviceTime, date("2026-10-13T12:22:30Z"))
    }

    func testAnActiveWarningReachesTheSnapshot() async throws {
        cloud.respond("queryDeviceWarning", dat: #"{"warning":[{"status":true,"title":"Battery low","code":"0x00000010"},{"status":false,"title":"Line fail"}]}"#)
        let s = try await service.fetchSnapshot()
        XCTAssertEqual(s.activeWarning, "Battery low")
    }

    func testAFailedReadingFailsTheSnapshotAndIsNotCached() async throws {
        _ = try await service.fetchSnapshot()
        clock.advance(21)
        cloud.breakTransport("queryDeviceLastData", with: URLError(.notConnectedToInternet))
        await assertThrows(try await service.fetchSnapshot()) { error in
            XCTAssertEqual(error as? DessMonitorError, .offline)
        }
        cloud.respond("queryDeviceLastData", dat: Fixtures.lastData)
        let s = try await service.fetchSnapshot()
        XCTAssertEqual(s.loadPowerW, 1154)
        XCTAssertEqual(cloud.count("webQueryDeviceEs"), 1, "a network failure does not throw the device away")
    }

    func testAFailedRefreshLeavesTheLastGoodReadingInPlace() async throws {
        let none = await service.lastSnapshot
        XCTAssertNil(none, "nothing before the first reading")
        let good = try await service.fetchSnapshot()

        // Five seconds later the user presses refresh and the network is gone.
        clock.advance(5)
        for action in ["queryDeviceLastData", "queryDeviceWarning", "webQueryCollectorsEs", "queryPlants"] {
            cloud.breakTransport(action, with: URLError(.networkConnectionLost))
        }
        await assertThrows(try await service.fetchSnapshot(force: true)) { error in
            XCTAssertEqual(error as? DessMonitorError, .offline)
            XCTAssertEqual(error.localizedDescription, "No connection to the inverter cloud.")
        }

        // The cache was not touched: an ordinary call inside the 20 s still answers from it...
        let requestsSoFar = cloud.calls.count
        let cached = try await service.fetchSnapshot()
        XCTAssertEqual(cached, good)
        XCTAssertEqual(cloud.calls.count, requestsSoFar, "answered without the network")

        // ...and once the 20 s are over the error is reported, while the last good reading stays
        // available for the panel to keep on screen.
        clock.advance(60)
        await assertThrows(try await service.fetchSnapshot()) { error in
            XCTAssertEqual(error as? DessMonitorError, .offline)
        }
        let kept = await service.lastSnapshot
        XCTAssertEqual(kept, good)
        XCTAssertEqual(cloud.logins, 1, "a network failure is not an auth failure: no new login")
        XCTAssertEqual(cloud.count("webQueryDeviceEs"), 1)
    }

    func testAFailedCurveRefreshLeavesTheLastGoodCurveInPlace() async throws {
        let good = try await service.fetchToday()
        clock.advance(301)
        cloud.breakTransport("queryDeviceDataOneDay", with: URLError(.timedOut))
        await assertThrows(try await service.fetchToday()) { error in
            XCTAssertEqual(error as? DessMonitorError, .timedOut)
        }
        let kept = await service.lastToday
        XCTAssertEqual(kept, good)
    }

    func testWithNoConnectionTheSecondDeviceListIsNotTried() async throws {
        cloud.breakTransport("webQueryDeviceEs", with: URLError(.notConnectedToInternet))
        await assertThrows(try await service.fetchSnapshot()) { error in
            XCTAssertEqual(error as? DessMonitorError, .offline)
        }
        XCTAssertEqual(cloud.count("queryDevices"), 0, "it could not have worked either")

        // The same when the login itself is refused: one login attempt, no second list.
        let refused = FakeCloud.withFixtures(config: TestAccount.config)
        refused.setLoginAnswer(Fixtures.failure(261, "ERR_PASSWORD_INVALID"))
        let other = InverterService(config: TestAccount.config, sessionStore: .memoryOnly, transport: refused, now: clock.reader)
        await assertThrows(try await other.fetchSnapshot()) { error in
            XCTAssertEqual(error as? DessMonitorError, .loginRejected(code: 261, desc: "ERR_PASSWORD_INVALID"))
        }
        XCTAssertEqual(refused.calls.map(\.action), ["authSource"])
    }

    func testAFetchInFlightIsSharedAndASlowLoginIsNotRepeated() async throws {
        // Hold the login back until all the callers are queued, so they really do overlap.
        let gate = Gate()
        let slow = SlowCloud(inner: cloud, loginGate: gate)
        let service = InverterService(config: TestAccount.config, sessionStore: store, transport: slow, now: clock.reader)

        async let a = service.fetchSnapshot()
        async let b = service.fetchSnapshot(force: true)
        async let c = service.fetchToday()
        async let d = service.fetchSnapshot()
        await gate.waitForWaiters(1)
        try await Task.sleep(nanoseconds: 50_000_000)   // let the other three callers queue up behind it
        XCTAssertEqual(gate.waiters, 1, "one request is out (the login); everyone else is waiting on it")
        XCTAssertEqual(cloud.logins, 0, "nothing has been answered yet")
        gate.open()

        let (sa, sb, _, sd) = try await (a, b, c, d)
        XCTAssertEqual(sa, sb)
        XCTAssertEqual(sa, sd)
        XCTAssertEqual(cloud.logins, 1, "one login for the three overlapping snapshots and the curve")
        XCTAssertEqual(cloud.count("webQueryDeviceEs"), 1)
        XCTAssertEqual(cloud.count("queryDeviceLastData"), 1, "one reading for the three snapshot callers")
        XCTAssertEqual(cloud.count("queryPlants"), 1)
    }

    func testADeviceTheCloudNoLongerKnowsIsLookedUpAgain() async throws {
        _ = try await service.fetchSnapshot()
        cloud.fail("queryDeviceLastData", code: 6, desc: "ERR_FORMAT_ERROR(pn: W0000000000000, devcode: 2452, devaddr: 1, sn: 00000000000000)")
        await assertThrows(try await service.fetchSnapshot(force: true)) { error in
            guard case .api(let action, let code, _)? = error as? DessMonitorError else { return XCTFail("\(error)") }
            XCTAssertEqual(action, "queryDeviceLastData")
            XCTAssertEqual(code, 6)
        }
        cloud.respond("queryDeviceLastData", dat: Fixtures.lastData)
        _ = try await service.fetchSnapshot(force: true)
        XCTAssertEqual(cloud.count("webQueryDeviceEs"), 2)
    }

    func testDeviceListFallsBackToQueryDevices() async throws {
        cloud.fail("webQueryDeviceEs", code: 1, desc: "ERR_FAIL")
        cloud.breakTransport("queryPlants", with: URLError(.timedOut))
        cloud.respond("webQueryCollectorsEs", dat: "{}")
        let s = try await service.fetchSnapshot()
        XCTAssertEqual(cloud.count("queryDevices"), 1)
        XCTAssertEqual(cloud.last("queryDevices")?.query, "queryDevices&page=0&pagesize=50&i18n=en_US")
        XCTAssertEqual(s.loadPowerW, 1154)
        XCTAssertEqual(s.deviceTime, date("2026-10-13T12:22:30Z"), "with no plant, the device list's own time zone is used")
    }

    func testWhenBothDeviceListsFailTheFirstErrorSurfaces() async throws {
        cloud.breakTransport("webQueryDeviceEs", with: URLError(.timedOut))
        cloud.breakTransport("queryDevices", with: URLError(.notConnectedToInternet))
        await assertThrows(try await service.fetchSnapshot()) { error in
            XCTAssertEqual(error as? DessMonitorError, .timedOut)
        }
        XCTAssertEqual(cloud.count("queryDeviceLastData"), 0)
    }

    func testAnAccountWithNoBoundInverterIsATypedError() async throws {
        cloud.respond("webQueryDeviceEs", dat: #"{"total":0,"device":[]}"#)
        await assertThrows(try await service.fetchSnapshot()) { error in
            XCTAssertEqual(error as? InverterDataError, .noDevice)
        }
        cloud.respond("webQueryDeviceEs", dat: #"{"device":[{"pn":"W0000000000000","sn":"00000000000000","devcode":0}]}"#)
        await assertThrows(try await service.fetchSnapshot()) { error in
            XCTAssertEqual(error as? InverterDataError, .noDevice, "device code 0: the stick is not bound yet")
        }
    }

    func testThePreferredSerialPicksAmongSeveralDevices() async throws {
        cloud.respond("webQueryDeviceEs", dat: """
        {"device":[{"pn":"W1111111111111","sn":"11111111111111","devcode":2400,"devaddr":1,"pid":5},
                   {"pn":"W0000000000000","sn":"00000000000000","devcode":2452,"devaddr":1,"pid":1}]}
        """)
        var config = TestAccount.config
        config.inverterSN = "00000000000000"
        _ = try await makeService(config).fetchSnapshot()
        XCTAssertTrue(cloud.last("queryDeviceLastData")?.query.contains("sn=00000000000000&") ?? false)

        let firstOnly = makeService()   // no preference: the first device
        _ = try await firstOnly.fetchSnapshot()
        XCTAssertTrue(cloud.last("queryDeviceLastData")?.query.contains("pn=W1111111111111&devcode=2400") ?? false)
    }

    func testARevokedSessionIsRenewedUnderneathTheService() async throws {
        _ = try await service.fetchSnapshot()
        clock.advance(600)
        cloud.revokeAll()
        let s = try await service.fetchSnapshot()
        XCTAssertEqual(s.loadPowerW, 1154)
        XCTAssertEqual(cloud.logins, 2, "one renewal, shared by the four parallel requests")
    }

    func testAMissingAccountFileSurfacesFromTheFetch() async throws {
        let missing = scratch.appendingPathComponent("absent.env").path
        let service = InverterService(envPath: missing, sessionStore: store)
        await assertThrows(try await service.fetchSnapshot()) { error in
            guard case .fileNotFound(let path)? = error as? InverterConfigError else {
                // A SHINEMONITOR_USER/PASSWORD pair exported in the test environment would get past the file check.
                return XCTAssertNotNil(error as? InverterConfigError ?? error as? DessMonitorError, "\(error)")
            }
            XCTAssertEqual(path, missing)
        }
    }

    // MARK: Day totals

    func testAFinishedDayIsReadOnce() async throws {
        let first = try await service.fetchDayTotals(day: "2026-10-12")
        let second = try await service.fetchDayTotals(day: "2026-10-12")
        XCTAssertEqual(first?.complete, true)
        XCTAssertEqual(second, first)
        XCTAssertEqual(cloud.count("queryDeviceDataOneDay"), 1)
    }

    func testTheDayStillGoingIsReadAgain() async throws {
        let first = try await service.fetchDayTotals(day: "2026-10-13")
        _ = try await service.fetchDayTotals(day: "2026-10-13")
        XCTAssertEqual(first?.complete, false)
        XCTAssertEqual(cloud.count("queryDeviceDataOneDay"), 2)
    }

    // MARK: Day curve

    func testTodayCurveFromTheCapturedDay() async throws {
        let curve = try await service.fetchToday()
        XCTAssertEqual(curve.day, "2026-10-13")
        XCTAssertEqual(curve.points.count, 9)
        XCTAssertEqual(curve.peakPvW, 4080)
        XCTAssertEqual(curve.points.last?.time, date("2026-10-13T12:22:30Z"))
        XCTAssertEqual(curve.dayStart, date("2026-10-12T19:00:00Z"))
        XCTAssertEqual(cloud.last("queryDeviceDataOneDay")?.query,
                       "queryDeviceDataOneDay&pn=W0000000000000&devcode=2452&devaddr=1&sn=00000000000000&date=2026-10-13&i18n=en_US",
                       "the plant's day, in the same form pull-history.mjs sends")
    }

    func testTodayCurveIsCachedForFiveMinutes() async throws {
        let first = try await service.fetchToday()
        clock.advance(299)
        let second = try await service.fetchToday()
        XCTAssertEqual(second, first)
        XCTAssertEqual(cloud.count("queryDeviceDataOneDay"), 1)

        clock.advance(2)
        _ = try await service.fetchToday()
        XCTAssertEqual(cloud.count("queryDeviceDataOneDay"), 2)
    }

    func testTodayFollowsThePlantsCalendarNotUTC() async throws {
        // 23:58 in Pakistan is 18:58 UTC on the 13th.
        clock = TestClock("2026-10-13T18:58:00Z")
        service = makeService()
        cloud.setResponder { action, parameters in
            guard action == "queryDeviceDataOneDay" else { return nil }
            return parameters["date"] == "2026-10-13" ? nil : Fixtures.failure(12, "ERR_NO_RECORD")
        }
        let beforeMidnight = try await service.fetchToday()
        XCTAssertEqual(beforeMidnight.day, "2026-10-13")
        XCTAssertEqual(beforeMidnight.points.count, 9)

        // Three minutes later it is 00:01 on the 14th there. The cache is younger than 5 minutes
        // but belongs to yesterday, and the new day has nothing stored yet.
        clock.advance(180)
        let afterMidnight = try await service.fetchToday()
        XCTAssertEqual(afterMidnight.day, "2026-10-14")
        XCTAssertTrue(afterMidnight.isEmpty, "ERR_NO_RECORD is an empty chart, not an error")
        XCTAssertEqual(afterMidnight.dayStart, date("2026-10-13T19:00:00Z"))
        XCTAssertTrue(cloud.last("queryDeviceDataOneDay")?.query.contains("date=2026-10-14") ?? false)

        clock.advance(60)
        _ = try await service.fetchToday()
        XCTAssertEqual(cloud.count("queryDeviceDataOneDay"), 2, "the empty day is cached like any other")
    }

    func testOtherCurveFailuresAreErrors() async throws {
        cloud.fail("queryDeviceDataOneDay", code: 1, desc: "ERR_FAIL")
        await assertThrows(try await service.fetchToday()) { error in
            XCTAssertEqual(error as? DessMonitorError, .api(action: "queryDeviceDataOneDay", code: 1, desc: "ERR_FAIL"))
        }
    }

    // MARK: The provider protocol

    func testTheServiceAndADemoProviderAreInterchangeable() async throws {
        let demo = StaticSnapshotProvider(snapshot: EnergySnapshot(pvPowerW: 3420, loadPowerW: 1980, batteryVoltage: 54.2,
                                                                   batteryChargeA: 24, gridVoltage: 232))
        var providers: [any SnapshotProviding] = [demo, service]
        providers.reverse()
        var modes: [InverterMode] = []
        for provider in providers {
            let snapshot = try await provider.fetchSnapshot()          // the protocol's no-argument form
            let forced = try await provider.fetchSnapshot(force: true)
            XCTAssertEqual(snapshot.loadPowerW, forced.loadPowerW)
            _ = try await provider.fetchToday()
            modes.append(snapshot.mode)
        }
        XCTAssertEqual(modes, [.battery, .solar])
        let demoCurve = try await demo.fetchToday()
        XCTAssertTrue(demoCurve.isEmpty)

        // On the concrete actor both spellings compile and mean the same thing.
        let a = try await service.fetchSnapshot()
        let b = try await service.fetchSnapshot(force: false)
        XCTAssertEqual(a, b)
    }

    // MARK: A stalled side lookup

    func testAStalledSideLookupDoesNotHoldUpTheReading() async throws {
        let stalled = StallingCloud(inner: cloud, stalledAction: "queryDeviceWarning")
        let service = InverterService(config: TestAccount.config, sessionStore: store, transport: stalled, now: clock.reader)
        await service.setSideLookupGrace(0.2)

        let started = ContinuousClock.now
        let snapshot = try await service.fetchSnapshot()
        let took = ContinuousClock.now - started

        XCTAssertLessThan(took, .seconds(5), "the snapshot waited for the stalled lookup")
        XCTAssertNil(snapshot.activeWarning)
        XCTAssertGreaterThan(snapshot.loadPowerW, 0)
        XCTAssertNotNil(snapshot.plantName, "lookups that did answer are still used")
    }

    func testAStalledPlantLookupDoesNotHoldUpTheReadingOrTheCurve() async throws {
        let stalled = StallingCloud(inner: cloud, stalledAction: "queryPlants")
        let service = InverterService(config: TestAccount.config, sessionStore: store, transport: stalled, now: clock.reader)
        await service.setSideLookupGrace(0.2)

        let started = ContinuousClock.now
        let snapshot = try await service.fetchSnapshot()
        _ = try await service.fetchToday()
        let took = ContinuousClock.now - started

        XCTAssertLessThan(took, .seconds(5), "a stalled plant lookup held things up")
        XCTAssertNil(snapshot.plantName)
        XCTAssertGreaterThan(snapshot.loadPowerW, 0)
    }
}

/// The fake cloud with one action that never answers (until the request is cancelled).
private struct StallingCloud: HTTPTransport {
    let inner: FakeCloud
    let stalledAction: String

    func get(_ url: URL) async throws -> (status: Int, body: Data) {
        if url.absoluteString.contains("&action=\(stalledAction)") {
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }
        return try await inner.get(url)
    }
}
