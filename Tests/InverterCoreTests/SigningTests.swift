import XCTest
@testable import InverterCore

/// The Swift signing against vectors produced by the real Node client (see SigningVectors.swift).
final class SigningTests: XCTestCase {
    private func profile(_ name: String) -> CloudProfile {
        CloudProfile.all.first { $0.name == name }!
    }

    func testSha1MatchesNode() {
        XCTAssertEqual(SigningVectors.hashes.count, 5)
        for vector in SigningVectors.hashes {
            XCTAssertEqual(DessSigning.sha1Hex(vector.text), vector.hex, "sha1 of \"\(vector.text)\"")
        }
    }

    func testLoginURLMatchesNodeByteForByte() {
        XCTAssertEqual(SigningVectors.logins.count, 4)
        for vector in SigningVectors.logins {
            let url = DessSigning.loginURLString(profile: profile(vector.profile), username: vector.user,
                                                 password: vector.password, salt: vector.salt)
            XCTAssertEqual(url, vector.url, "login as \"\(vector.user)\"")
        }
    }

    func testLoginSignsTheRawUsernameButSendsItEncoded() {
        // "solar user+tag@example.com": the URL carries %20 %2B %40, the signature covers the raw text.
        let vector = SigningVectors.logins[1]
        let p = profile(vector.profile)
        let rawAction = "&action=authSource&usr=\(vector.user)&company-key=\(p.companyKey)" + DessSigning.suffix(p)
        let expected = DessSigning.sha1Hex(vector.salt + DessSigning.sha1Hex(vector.password) + rawAction)
        XCTAssertTrue(vector.url.contains("sign=\(expected)&"))
        XCTAssertTrue(vector.url.contains("usr=solar%20user%2Btag%40example.com&"))

        let encodedAction = "&action=authSource&usr=\(DessSigning.encodeURIComponent(vector.user))&company-key=\(p.companyKey)" + DessSigning.suffix(p)
        let wrong = DessSigning.sha1Hex(vector.salt + DessSigning.sha1Hex(vector.password) + encodedAction)
        XCTAssertFalse(vector.url.contains(wrong), "signing the encoded username would be the wrong signature")
    }

    func testRequestURLMatchesNodeByteForByte() {
        XCTAssertEqual(SigningVectors.requests.count, 4)
        for vector in SigningVectors.requests {
            let url = DessSigning.requestURLString(profile: profile(vector.profile), secret: vector.secret,
                                                   token: vector.token, action: vector.action, salt: vector.salt)
            XCTAssertEqual(url, vector.url, vector.action)
        }
    }

    func testRequestDoesNotCarryTheAppSuffix() {
        let vector = SigningVectors.requests[0]
        XCTAssertFalse(vector.url.contains("_app_id_"))
        let url = DessSigning.requestURLString(profile: .dessmonitor, secret: "s", token: "t", action: "webQueryDeviceEs", salt: "1")
        XCTAssertFalse(url.contains("_app_id_"))
        XCTAssertTrue(url.hasSuffix("&token=t&action=webQueryDeviceEs"))
    }

    func testEncodeURIComponentKeepsExactlyTheJavaScriptSet() {
        let untouched = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
        XCTAssertEqual(DessSigning.encodeURIComponent(untouched), untouched)
        XCTAssertEqual(DessSigning.encodeURIComponent(" +@&=/?#%"), "%20%2B%40%26%3D%2F%3F%23%25")
        XCTAssertEqual(DessSigning.encodeURIComponent("用户 ñ"), "%E7%94%A8%E6%88%B7%20%C3%B1")
        XCTAssertEqual(DessSigning.encodeURIComponent("[]{}|\\^`\"<>,;:$"), "%5B%5D%7B%7D%7C%5C%5E%60%22%3C%3E%2C%3B%3A%24")
    }

    func testSaltIsWholeMilliseconds() {
        XCTAssertEqual(DessSigning.salt(at: Date(timeIntervalSince1970: 1_760_000_000.123)), "1760000000123")
        XCTAssertEqual(DessSigning.salt(at: Date(timeIntervalSince1970: 1_700_000_000)), "1700000000000")
    }

    // MARK: The whole read flow on the wire

    /// `SigningVectors.flow` is every URL the Node dashboard (`fetchCloudPayload()` in lib/cloud.js),
    /// its fallback device list and pull-history.mjs sent to a canned cloud. The app is run against
    /// the same canned cloud at the same clock. Every URL it sends has to be one of Node's, byte for
    /// byte: same action, same parameters in the same order, same salt, same signature.
    func testTheAppSendsTheSameURLsAsTheNodeClient() async throws {
        let config = InverterConfig(profile: .dessmonitor, user: SigningVectors.flowUser, password: SigningVectors.flowPassword)
        let moment = Date(timeIntervalSince1970: SigningVectors.flowClockMs / 1000)
        let node = Dictionary(grouping: SigningVectors.flow, by: \.action).mapValues { $0.map(\.url) }

        func run(_ prepare: (FakeCloud) -> Void, _ work: (InverterService) async throws -> Void) async throws -> [String] {
            let cloud = FakeCloud.withFixtures(config: config)
            prepare(cloud)
            let service = InverterService(config: config, sessionStore: .memoryOnly, transport: cloud, now: { moment })
            try await work(service)
            XCTAssertEqual(cloud.signatureFailures, [])
            return cloud.urls
        }
        func action(of url: String) -> String {
            url.range(of: "&action=").map { String(url[$0.upperBound...].prefix { $0 != "&" }) } ?? ""
        }

        // The normal path: login, device list, reading, warnings, collectors, plant, today's curve.
        let normal = try await run({ _ in }) { service in
            _ = try await service.fetchSnapshot()
            let curve = try await service.fetchToday()
            XCTAssertEqual(curve.day, SigningVectors.flowDay)
        }
        XCTAssertEqual(Set(normal.map(action)), ["authSource", "webQueryDeviceEs", "queryDeviceLastData", "queryDeviceWarning",
                                                 "webQueryCollectorsEs", "queryPlants", "queryDeviceDataOneDay"])
        // The path where the first device list fails and the fallback is used.
        let fallback = try await run({ $0.fail("webQueryDeviceEs", code: 1, desc: "ERR_FAIL") }) { service in
            _ = try await service.fetchSnapshot()
        }
        XCTAssertTrue(fallback.map(action).contains("queryDevices"))

        for url in normal + fallback {
            let name = action(of: url)
            XCTAssertTrue(node[name]?.contains(url) ?? false, "\(name): the app sent a URL the Node client does not send:\n\(url)")
        }
        // And nothing the Node vectors hold is left unexercised.
        let sent = Set(normal + fallback)
        for vector in SigningVectors.flow {
            XCTAssertTrue(sent.contains(vector.url), "\(vector.action) was never sent by the app")
        }
    }

    func testSignedURLsSurviveFoundationUnchanged() throws {
        // URLSession sends url.absoluteString. If Foundation re-encoded anything, the server
        // would see a different string from the one that was signed.
        for vector in SigningVectors.requests {
            let url = try XCTUnwrap(URL(string: vector.url, encodingInvalidCharacters: true))
            XCTAssertEqual(url.absoluteString, vector.url)
        }
        for vector in SigningVectors.logins {
            let url = try XCTUnwrap(URL(string: vector.url, encodingInvalidCharacters: true))
            XCTAssertEqual(url.absoluteString, vector.url)
        }
    }
}
