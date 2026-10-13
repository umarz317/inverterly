import XCTest
@testable import InverterCore

/// The client against a fake cloud that verifies signatures. No network.
final class ClientTests: ScratchTestCase {
    private let plants = "queryPlants&page=0&pagesize=20&i18n=en_US"
    private var clock: TestClock!
    private var cloud: FakeCloud!

    override func setUpWithError() throws {
        try super.setUpWithError()
        clock = TestClock()
        cloud = FakeCloud.withFixtures(config: TestAccount.config)
    }

    private func makeClient(_ config: InverterConfig = TestAccount.config, store: SessionStore? = nil) -> DessMonitorClient {
        DessMonitorClient(config: config, sessionStore: store ?? self.store, transport: cloud, now: clock.reader)
    }

    private func savedSession() throws -> DessSession {
        try JSONDecoder().decode(DessSession.self, from: Data(contentsOf: sessionFile))
    }

    private func seedSession(token: String, secret: String, config: InverterConfig = TestAccount.config,
                             expiresIn: TimeInterval = 6 * 24 * 3600, age: TimeInterval = 24 * 3600) throws {
        let nowMs = clock.now.timeIntervalSince1970 * 1000
        try store.save(DessSession(profile: config.profile.name, baseURL: config.profile.baseURL, secret: secret, token: token,
                                   expireAt: nowMs + expiresIn * 1000,
                                   account: DessSession.fingerprint(profile: config.profile, user: config.user),
                                   createdAt: nowMs - age * 1000))
    }

    // MARK: Login and persistence

    func testFirstRequestLogsInAndSignsCorrectly() async throws {
        let dat = try await makeClient().request(plants)
        XCTAssertEqual(dat["plant"]?.arrayValue?.first?["name"]?.stringValue, "PLANT")
        XCTAssertEqual(cloud.logins, 1)
        XCTAssertEqual(cloud.calls.map(\.action), ["authSource", "queryPlants"])
        XCTAssertEqual(cloud.last("queryPlants")?.query, plants, "the action goes out exactly as written")
        XCTAssertEqual(cloud.last("queryPlants")?.token, "token-1")
        XCTAssertEqual(cloud.signatureFailures, [], "the fake recomputes every signature like the server")
    }

    func testSessionIsSavedWithOwnerOnlyPermissions() async throws {
        _ = try await makeClient().request(plants)
        XCTAssertEqual(try permissions(of: sessionFile), 0o600)
        XCTAssertEqual(try permissions(of: sessionFile.deletingLastPathComponent()), 0o700)

        let saved = try savedSession()
        XCTAssertEqual(saved.profile, "dessmonitor")
        XCTAssertEqual(saved.baseURL, "https://web.dessmonitor.com/public/")
        XCTAssertEqual(saved.token, "token-1")
        XCTAssertEqual(saved.secret, "secret-1")
        XCTAssertEqual(saved.expireAt, clock.now.timeIntervalSince1970 * 1000 + 604_800_000, "expire seconds from the login answer")

        let text = try String(contentsOf: sessionFile, encoding: .utf8)
        XCTAssertTrue(text.contains("\"base_url\""), "same key names as the Node client's session file")
        XCTAssertFalse(text.contains(TestAccount.config.user), "the account name is stored only as a fingerprint")
        XCTAssertFalse(text.contains(TestAccount.config.password))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: sessionFile.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["session.json"], "no temporary file left behind")
    }

    func testSavingOverAnExistingSessionKeepsItPrivate() async throws {
        try seedSession(token: "stale", secret: "stale-secret")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sessionFile.path)
        _ = try await makeClient().request(plants)   // "stale" is unknown to the cloud, so this logs in and saves again
        XCTAssertEqual(try permissions(of: sessionFile), 0o600)
        XCTAssertEqual(try savedSession().token, "token-1")
    }

    func testASessionFileLeftReadableByOthersIsClosedAgainWhenRead() async throws {
        cloud.issue(token: "ok", secret: "ok-secret")
        try seedSession(token: "ok", secret: "ok-secret")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sessionFile.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sessionFile.deletingLastPathComponent().path)

        _ = try await makeClient().request(plants)
        XCTAssertEqual(cloud.logins, 0, "the saved session was good, so nothing was rewritten")
        XCTAssertEqual(try permissions(of: sessionFile), 0o600)

        // And a save closes the folder as well, even though it already existed.
        try store.save(try savedSession())
        XCTAssertEqual(try permissions(of: sessionFile.deletingLastPathComponent()), 0o700)
    }

    func testASavedSessionIsReusedByTheNextLaunch() async throws {
        _ = try await makeClient().request(plants)
        XCTAssertEqual(cloud.logins, 1)

        let nextLaunch = makeClient()
        _ = try await nextLaunch.request(plants)
        _ = try await nextLaunch.request("webQueryDeviceEs")
        XCTAssertEqual(cloud.logins, 1, "no second login")
        XCTAssertEqual(cloud.calls.last?.token, "token-1")
    }

    func testMemoryOnlyStoreWritesNothing() async throws {
        _ = try await makeClient(store: .memoryOnly).request(plants)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile.path))
    }

    func testLoginAnswerMayCarryNumbersAsStrings() async throws {
        cloud.issue(token: "tok", secret: "sec")
        cloud.setLoginAnswer(Data(#"{"err":"0","desc":"ERR_NONE","dat":{"secret":"sec","token":"tok","expire":"3600"}}"#.utf8))
        _ = try await makeClient().request(plants)
        XCTAssertEqual(try savedSession().expireAt, clock.now.timeIntervalSince1970 * 1000 + 3_600_000)
    }

    func testMissingExpiryMeansSevenDaysLikeTheNodeClient() async throws {
        cloud.issue(token: "tok", secret: "sec")
        cloud.setLoginAnswer(Data(#"{"err":0,"dat":{"secret":"sec","token":"tok","expire":0}}"#.utf8))
        _ = try await makeClient().request(plants)
        XCTAssertEqual(try savedSession().expireAt, clock.now.timeIntervalSince1970 * 1000 + 604_800_000)
    }

    // MARK: Which saved sessions are acceptable

    func testASessionAboutToExpireIsNotUsed() async throws {
        cloud.issue(token: "old", secret: "old-secret")
        try seedSession(token: "old", secret: "old-secret", expiresIn: 59)   // inside the one-minute margin
        _ = try await makeClient().request(plants)
        XCTAssertEqual(cloud.logins, 1)
        XCTAssertEqual(cloud.last("queryPlants")?.token, "token-1")
    }

    func testASessionWithAMinuteAndABitLeftIsStillUsed() async throws {
        cloud.issue(token: "old", secret: "old-secret")
        try seedSession(token: "old", secret: "old-secret", expiresIn: 61)
        _ = try await makeClient().request(plants)
        XCTAssertEqual(cloud.logins, 0)
        XCTAssertEqual(cloud.last("queryPlants")?.token, "old")
    }

    func testASessionSavedForAnotherAccountOrProfileIsNotUsed() async throws {
        cloud.issue(token: "theirs", secret: "their-secret")
        let other = InverterConfig(profile: .dessmonitor, user: "someone-else@example.com", password: "x")
        try seedSession(token: "theirs", secret: "their-secret", config: other)
        _ = try await makeClient().request(plants)
        XCTAssertEqual(cloud.last("queryPlants")?.token, "token-1", "logged in as this account instead")

        var moved = TestAccount.config
        moved.profile.baseURL = "https://elsewhere.invalid/public/"
        let movedCloud = FakeCloud.withFixtures(config: moved)
        let client = DessMonitorClient(config: moved, sessionStore: store, transport: movedCloud, now: clock.reader)
        _ = try await client.request(plants)
        XCTAssertEqual(movedCloud.logins, 1, "a session for another base URL is not sent to this one")
    }

    func testACorruptSessionFileIsIgnored() async throws {
        try FileManager.default.createDirectory(at: sessionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: sessionFile)
        _ = try await makeClient().request(plants)
        XCTAssertEqual(cloud.logins, 1)
        XCTAssertEqual(try savedSession().token, "token-1")
    }

    // MARK: Re-login on an auth failure

    func testARefusedSavedSessionLogsInAgainOnceAndRetries() async throws {
        try seedSession(token: "revoked-elsewhere", secret: "whatever")   // the cloud does not know this token
        let dat = try await makeClient().request(plants)
        XCTAssertEqual(dat["plant"]?.arrayValue?.count, 1)
        XCTAssertEqual(cloud.logins, 1)
        XCTAssertEqual(cloud.calls.map(\.action), ["queryPlants", "authSource", "queryPlants"])
        XCTAssertEqual(cloud.calls.map(\.token), ["revoked-elsewhere", nil, "token-1"])
        XCTAssertEqual(try savedSession().token, "token-1", "the new session replaces the dead one on disk")
    }

    func testASessionWithTheWrongSecretIsRenewedToo() async throws {
        cloud.issue(token: "known", secret: "right-secret")
        try seedSession(token: "known", secret: "wrong-secret")   // the server answers ERR_SIGN
        _ = try await makeClient().request(plants)
        XCTAssertEqual(cloud.calls.map(\.action), ["queryPlants", "authSource", "queryPlants"])
        XCTAssertEqual(cloud.signatureFailures, ["queryPlants"])
    }

    func testASessionRevokedMidRunIsRenewedOnceForAllWaitingRequests() async throws {
        let client = makeClient()
        _ = try await client.request(plants)
        clock.advance(3600)
        cloud.revokeAll()

        let action = plants
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask { _ = try await client.request(action) }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(cloud.logins, 2, "six refused requests, one new login")
        XCTAssertEqual(cloud.last("queryPlants")?.token, "token-2")
    }

    func testFailuresThatArriveWhileTheRenewalIsInFlightJoinIt() async throws {
        // The reentrancy case. The actor is free while a login is awaited, so the other refused
        // requests reach the renewal code before the first login has come back. Two gates make
        // that certain: all six requests are out on the dead session before any is answered,
        // and the login that follows is held until all six refusals have been dealt with.
        let dataGate = Gate()
        let loginGate = Gate()
        let slow = SlowCloud(inner: cloud, loginGate: loginGate, dataGate: dataGate)
        let client = DessMonitorClient(config: TestAccount.config, sessionStore: store, transport: slow, now: clock.reader)
        try seedSession(token: "revoked-elsewhere", secret: "whatever")   // the cloud does not know this token

        let action = plants
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask { _ = try await client.request(action) }
            }
            await dataGate.waitForWaiters(6)
            XCTAssertEqual(dataGate.waiters, 6, "six requests in flight on the saved session")
            XCTAssertEqual(cloud.calls.count, 0)
            dataGate.open()   // six refusals come back

            await loginGate.waitForWaiters(1)
            try await Task.sleep(nanoseconds: 150_000_000)   // time for the other five to reach the renewal
            XCTAssertEqual(loginGate.waiters, 1, "exactly one login is out, however many requests were refused")
            XCTAssertEqual(cloud.count("queryPlants"), 6)
            XCTAssertEqual(cloud.logins, 0, "and it has not been answered yet")
            loginGate.open()
            try await group.waitForAll()
        }
        XCTAssertEqual(cloud.logins, 1, "six refused requests, one login")
        XCTAssertEqual(cloud.count("queryPlants"), 12, "and each was retried exactly once")
        XCTAssertEqual(cloud.calls.suffix(6).map(\.token), Array(repeating: "token-1", count: 6))
        XCTAssertEqual(try savedSession().token, "token-1")
    }

    func testFirstRequestsThatOverlapASlowLoginShareIt() async throws {
        let gate = Gate()
        let slow = SlowCloud(inner: cloud, loginGate: gate)
        let client = DessMonitorClient(config: TestAccount.config, sessionStore: store, transport: slow, now: clock.reader)
        let action = plants
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { _ = try await client.request(action) }
            }
            await gate.waitForWaiters(1)
            try await Task.sleep(nanoseconds: 100_000_000)   // the other seven arrive while it is out
            XCTAssertEqual(gate.waiters, 1, "one login is out; nobody started a second")
            XCTAssertEqual(cloud.calls.count, 0)
            gate.open()
            try await group.waitForAll()
        }
        XCTAssertEqual(cloud.logins, 1)
        XCTAssertEqual(cloud.count("queryPlants"), 8)
    }

    func testConcurrentFirstRequestsShareOneLogin() async throws {
        let client = makeClient()
        let action = plants
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { _ = try await client.request(action) }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(cloud.logins, 1)
        XCTAssertEqual(cloud.count("queryPlants"), 8)
    }

    func testAnAuthFailureRightAfterAFreshLoginIsNotRetried() async throws {
        cloud.fail("queryPlants", code: 10, desc: "ERR_NO_AUTH")   // refused no matter how new the token is
        let client = makeClient()

        await assertThrows(try await client.request(plants)) { error in
            XCTAssertEqual(error as? DessMonitorError, .api(action: "queryPlants", code: 10, desc: "ERR_NO_AUTH"))
        }
        XCTAssertEqual(cloud.calls.map(\.action), ["authSource", "queryPlants"], "the login was made by this very request: no second try")

        await assertThrows(try await client.request(plants)) { _ in }
        XCTAssertEqual(cloud.logins, 1, "the session is seconds old; logging in again would only loop")

        clock.advance(61)
        await assertThrows(try await client.request(plants)) { error in
            XCTAssertEqual((error as? DessMonitorError)?.isAuthFailure, true)
        }
        XCTAssertEqual(cloud.logins, 2, "after a minute one renewal is allowed")
        XCTAssertEqual(cloud.count("queryPlants"), 4, "and the retry happens exactly once")
    }

    func testAnActionRefusedOnEveryNewSessionDoesNotCostALoginAMinuteForever() async throws {
        // The account is simply not allowed this query: every session, however new, gets ERR_NO_AUTH.
        cloud.fail("webQueryCollectorsEs", code: 10, desc: "ERR_NO_AUTH")
        let client = makeClient()
        let collectors = "webQueryCollectorsEs&page=0&pagesize=50"

        // An app polling every 30 s for two hours.
        for _ in 0..<240 {
            _ = try await client.request(plants)                     // the rest of the API keeps working
            await assertThrows(try await client.request(collectors)) { error in
                XCTAssertEqual((error as? DessMonitorError)?.isAuthFailure, true)
            }
            clock.advance(30)
        }
        // Waits of 1, 2, 4, 8, 16, 32, 32 ... minutes between renewals, not one a minute.
        XCTAssertLessThanOrEqual(cloud.logins, 9, "\(cloud.logins) logins in two hours")
        XCTAssertGreaterThanOrEqual(cloud.logins, 5, "it does still try again now and then")
        XCTAssertEqual(cloud.count("queryPlants"), 240, "the refused action never cost the working ones a request")

        // When the cloud relents, the action works and its backoff is forgotten.
        cloud.respond("webQueryCollectorsEs", dat: Fixtures.collectors)
        _ = try await client.request(collectors)
    }

    func testRenewalBackoffDoublesAndStopsAtHalfAnHour() {
        XCTAssertEqual((0...8).map { DessMonitorClient.renewalBackoff(afterRefusals: $0) },
                       [60, 60, 120, 240, 480, 960, 1920, 1920, 1920])
    }

    func testASessionStampedInTheFutureCanStillBeRenewed() async throws {
        // The Mac's clock was an hour ahead when the session was saved, and has since been corrected.
        try seedSession(token: "revoked-elsewhere", secret: "whatever", age: -3600)
        _ = try await makeClient().request(plants)
        XCTAssertEqual(cloud.calls.map(\.action), ["queryPlants", "authSource", "queryPlants"],
                       "its negative age must not read as 'brand new, do not renew'")
    }

    func testASessionThatExpiresMidRunIsReplacedByOneLogin() async throws {
        let client = makeClient()
        _ = try await client.request(plants)
        XCTAssertEqual(cloud.logins, 1)

        // Seven days later (less the one-minute margin) the session has run out. Nothing was
        // refused: the client sees the expiry itself, logs in once, and sends each request once.
        clock.advance(7 * 24 * 3600 - 30)
        let action = plants
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { _ = try await client.request(action) }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(cloud.logins, 2, "five requests at the moment of expiry, one login")
        XCTAssertEqual(cloud.count("queryPlants"), 6, "no request was sent on the expired session, so none was retried")
        XCTAssertEqual(cloud.calls.suffix(5).map(\.token), Array(repeating: "token-2", count: 5))
        XCTAssertEqual(try savedSession().token, "token-2")
    }

    func testAMissingPermissionDoesNotCauseALogin() async throws {
        // ERR_NO_PERMISSION (0x000B) is the account not being allowed a query. It is not ERR_NO_AUTH.
        cloud.issue(token: "ok", secret: "ok-secret")
        try seedSession(token: "ok", secret: "ok-secret")
        cloud.fail("webQueryCollectorsEs", code: 11, desc: "ERR_NO_PERMISSION")
        let client = makeClient()
        for _ in 0..<3 {
            await assertThrows(try await client.request("webQueryCollectorsEs&page=0&pagesize=50")) { error in
                XCTAssertEqual(error as? DessMonitorError, .api(action: "webQueryCollectorsEs", code: 11, desc: "ERR_NO_PERMISSION"))
            }
            clock.advance(120)
        }
        XCTAssertEqual(cloud.logins, 0)
        XCTAssertEqual(cloud.count("webQueryCollectorsEs"), 3)
    }

    func testOtherAPIErrorsAreNotRetried() async throws {
        cloud.fail("queryPlants", code: 6, desc: "ERR_FORMAT_ERROR(pn: X, devcode: 1)")
        try seedSession(token: "ok", secret: "ok-secret", age: 3600)
        cloud.issue(token: "ok", secret: "ok-secret")
        await assertThrows(try await makeClient().request(plants)) { error in
            XCTAssertEqual(error as? DessMonitorError, .api(action: "queryPlants", code: 6, desc: "ERR_FORMAT_ERROR(pn: X, devcode: 1)"))
            XCTAssertEqual((error as? DessMonitorError)?.isAuthFailure, false)
        }
        XCTAssertEqual(cloud.calls.map(\.action), ["queryPlants"])
    }

    // MARK: Login failures

    func testARejectedLoginIsTypedAndNotHammered() async throws {
        cloud.setLoginAnswer(Fixtures.failure(261, "ERR_PASSWORD_INVALID"))
        let client = makeClient()

        await assertThrows(try await client.request(plants)) { error in
            XCTAssertEqual(error as? DessMonitorError, .loginRejected(code: 261, desc: "ERR_PASSWORD_INVALID"))
        }
        await assertThrows(try await client.request(plants)) { error in
            XCTAssertEqual(error as? DessMonitorError, .loginRejected(code: 261, desc: "ERR_PASSWORD_INVALID"))
        }
        XCTAssertEqual(cloud.logins, 1, "a refused password is not sent again for a minute")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile.path))

        clock.advance(61)
        cloud.setLoginAnswer(nil)
        _ = try await client.request(plants)
        XCTAssertEqual(cloud.logins, 2)
    }

    func testAWrongPasswordIsNotSentEveryMinuteAllDay() async throws {
        // The password was changed on the vendor's side. The app polls every 30 s for two hours.
        cloud.setLoginAnswer(Fixtures.failure(16, "ERR_PASSWORD_VERIF_FAIL"))
        let client = makeClient()
        for _ in 0..<240 {
            await assertThrows(try await client.request(plants)) { error in
                XCTAssertEqual(error as? DessMonitorError, .loginRejected(code: 16, desc: "ERR_PASSWORD_VERIF_FAIL"))
            }
            clock.advance(30)
        }
        XCTAssertLessThanOrEqual(cloud.logins, 8, "waits of 1, 2, 4, 8, 16, 32, 32 minutes: \(cloud.logins) attempts in two hours, not 120")
        XCTAssertGreaterThanOrEqual(cloud.logins, 6)
        XCTAssertEqual(cloud.count("queryPlants"), 0)

        // Once a login works, the slate is clean: the next refusal starts again at one minute.
        clock.advance(1920)
        cloud.setLoginAnswer(nil)
        _ = try await client.request(plants)
        let before = cloud.logins
        cloud.revokeAll()
        cloud.setLoginAnswer(Fixtures.failure(16, "ERR_PASSWORD_VERIF_FAIL"))
        clock.advance(120)
        await assertThrows(try await client.request(plants)) { _ in }
        clock.advance(61)
        await assertThrows(try await client.request(plants)) { _ in }
        XCTAssertEqual(cloud.logins, before + 2, "a minute after the first new refusal it may try once more")
    }

    func testNoCredentialsAndNoSessionIsATypedError() async throws {
        let empty = InverterConfig(profile: .dessmonitor, user: "tester@example.com", password: "")
        await assertThrows(try await makeClient(empty).request(plants)) { error in
            XCTAssertEqual(error as? DessMonitorError, .missingCredentials)
        }
        XCTAssertEqual(cloud.calls, [])
    }

    // MARK: Secrets never leave through errors

    func testServerTextIsScrubbedOfTheTokenAndURLs() async throws {
        let client = makeClient()
        _ = try await client.request(plants)
        cloud.fail("webQueryDeviceEs", code: 1, desc: "ERR_FAIL(token-1 with secret-1 at https://web.dessmonitor.com/public/?sign=abc&token=token-1)")
        await assertThrows(try await client.request("webQueryDeviceEs")) { error in
            for text in [error.localizedDescription, String(describing: error), String(reflecting: error)] {
                XCTAssertFalse(text.contains("token-1"), text)
                XCTAssertFalse(text.contains("secret-1"), text)
                XCTAssertFalse(text.contains("sign="), text)
            }
            XCTAssertTrue(error.localizedDescription.contains("ERR_FAIL"))
        }
    }

    func testTransportErrorsLoseTheirURL() async throws {
        let client = makeClient()
        _ = try await client.request(plants)
        let leaky = "https://web.dessmonitor.com/public/?sign=abc&salt=1&token=token-1&action=webQueryDeviceEs"
        let userInfo: [String: Any] = [NSURLErrorFailingURLStringErrorKey: leaky, NSURLErrorFailingURLErrorKey: URL(string: leaky)!]

        let expectations: [(URLError.Code, DessMonitorError)] = [
            (.timedOut, .timedOut),
            (.notConnectedToInternet, .offline),
            (.cannotFindHost, .offline),
        ]
        for (code, expected) in expectations {
            cloud.breakTransport("webQueryDeviceEs", with: URLError(code, userInfo: userInfo))
            await assertThrows(try await client.request("webQueryDeviceEs")) { error in
                XCTAssertEqual(error as? DessMonitorError, expected)
            }
        }

        cloud.breakTransport("webQueryDeviceEs", with: URLError(.badServerResponse, userInfo: userInfo))
        await assertThrows(try await client.request("webQueryDeviceEs")) { error in
            guard case .network(let code, _)? = error as? DessMonitorError else { return XCTFail("expected .network, got \(error)") }
            XCTAssertEqual(code, URLError.Code.badServerResponse.rawValue)
            for text in [error.localizedDescription, String(describing: error), String(reflecting: error)] {
                XCTAssertFalse(text.contains("token-1"), text)
                XCTAssertFalse(text.contains("sign="), text)
            }
        }

        struct Odd: Error {}
        cloud.breakTransport("webQueryDeviceEs", with: Odd())
        await assertThrows(try await client.request("webQueryDeviceEs")) { error in
            guard case .network? = error as? DessMonitorError else { return XCTFail("expected .network, got \(error)") }
        }
    }

    func testAnAnswerThatIsNotJSONIsATypedError() async throws {
        cloud.respond("webQueryDeviceEs", body: Data("<html>502 Bad Gateway</html>".utf8))
        let client = makeClient()
        await assertThrows(try await client.request("webQueryDeviceEs")) { error in
            XCTAssertEqual(error as? DessMonitorError, .badResponse(action: "webQueryDeviceEs", status: 200))
        }
    }

    func testErrorClassification() {
        XCTAssertTrue(DessMonitorError.api(action: "a", code: 10, desc: "ERR_NO_AUTH").isAuthFailure)
        XCTAssertTrue(DessMonitorError.api(action: "a", code: 4, desc: "ERR_SIGN").isAuthFailure)
        XCTAssertTrue(DessMonitorError.api(action: "a", code: 99, desc: "ERR_TOKEN_EXPIRED").isAuthFailure)
        XCTAssertFalse(DessMonitorError.api(action: "a", code: 12, desc: "ERR_NO_RECORD").isAuthFailure)
        XCTAssertFalse(DessMonitorError.api(action: "a", code: 11, desc: "ERR_NO_PERMISSION").isAuthFailure,
                       "a missing permission is not cured by logging in again")
        XCTAssertFalse(DessMonitorError.api(action: "a", code: 5, desc: "ERR_SALT").isAuthFailure)
        XCTAssertFalse(DessMonitorError.api(action: "a", code: 263, desc: "ERR_COLLECTOR_OFFLINE").isAuthFailure)
        XCTAssertFalse(DessMonitorError.timedOut.isAuthFailure)
        XCTAssertFalse(DessMonitorError.loginRejected(code: 10, desc: "ERR_NO_AUTH").isAuthFailure)
        XCTAssertTrue(DessMonitorError.api(action: "a", code: 12, desc: "ERR_NO_RECORD").isNoRecord)
        XCTAssertFalse(DessMonitorError.api(action: "a", code: 6, desc: "ERR_FORMAT_ERROR").isNoRecord)
    }

    func testSessionDescriptionHidesItsSecrets() {
        let session = DessSession(profile: "dessmonitor", baseURL: "https://x/", secret: "SECRET-VALUE", token: "TOKEN-VALUE",
                                  expireAt: 1, account: "abc", createdAt: 0)
        var dumped = ""
        dump(session, to: &dumped)
        for text in ["\(session)", String(reflecting: session), dumped] {
            XCTAssertFalse(text.contains("SECRET-VALUE"), text)
            XCTAssertFalse(text.contains("TOKEN-VALUE"), text)
        }
    }

    func testDumpingTheClientShowsNeitherThePasswordNorTheSession() async throws {
        let client = makeClient()
        _ = try await client.request(plants)   // it now holds token-1 / secret-1 as well as the password
        var dumped = ""
        dump(client, to: &dumped)
        let mirrored = Mirror(reflecting: client).children.map { "\($0.label ?? ""): \($0.value)" }.joined(separator: " ")
        for text in [dumped, mirrored, "\(client)", String(reflecting: client)] {
            XCTAssertFalse(text.contains(TestAccount.config.password), text)
            XCTAssertFalse(text.contains("token-1"), text)
            XCTAssertFalse(text.contains("secret-1"), text)
            XCTAssertFalse(text.contains(TestAccount.config.user), text)
        }
        XCTAssertTrue(dumped.contains("dessmonitor"))
    }

    func testARejectedLoginNeverEchoesThePasswordOrItsHash() async throws {
        let password = TestAccount.config.password
        let hash = DessSigning.sha1Hex(password)
        cloud.setLoginAnswer(Fixtures.failure(261, "ERR_PASSWORD_INVALID(pwd: \(password), sha1: \(hash), see https://web.dessmonitor.com/public/?sign=abc)"))
        await assertThrows(try await makeClient().request(plants)) { error in
            for text in [error.localizedDescription, String(describing: error), String(reflecting: error)] {
                XCTAssertFalse(text.contains(password), text)
                XCTAssertFalse(text.contains(hash), text)
                XCTAssertFalse(text.contains("sign="), text)
            }
            XCTAssertTrue(error.localizedDescription.contains("ERR_PASSWORD_INVALID"))
        }
    }

    /// The standard store is where the brief says, and nowhere near the Node project.
    func testStandardSessionLocation() throws {
        let path = try XCTUnwrap(SessionStore.standard.fileURL?.path)
        XCTAssertTrue(path.hasSuffix("/Library/Application Support/Inverterly/session.json"), path)
        XCTAssertFalse(path.contains("inverter-control"))
    }
}
