import Foundation
import XCTest
@testable import InverterCore

/// A clock the test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    /// Default: 17:25 in Pakistan on the day the fixtures were captured.
    init(_ iso: String = "2026-10-13T12:25:00Z") {
        current = ISO8601DateFormatter().date(from: iso)!
    }

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
    var reader: @Sendable () -> Date { { self.now } }
}

/// Stands in for the vendor cloud. It checks every signature the way the real server does
/// (a wrong one gets `ERR_SIGN`), hands out a new token per login, and answers each action
/// with whatever the test put in `responses`.
final class FakeCloud: HTTPTransport, @unchecked Sendable {
    struct Call: Equatable {
        var action: String
        /// Everything after `&action=`, as sent.
        var query: String
        var token: String?
    }

    let profile: CloudProfile
    let user: String
    let password: String

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _urls: [String] = []
    private var _logins = 0
    private var _issued: [String: String] = [:]
    private var _revoked: Set<String> = []
    private var _responses: [String: Data] = [:]
    private var _errors: [String: Error] = [:]
    private var _loginAnswer: Data?
    private var _signatureFailures: [String] = []
    private var _responder: (@Sendable (_ action: String, _ parameters: [String: String]) -> Data?)?

    init(config: InverterConfig) {
        profile = config.profile
        user = config.user
        password = config.password
    }

    // MARK: Test controls

    var calls: [Call] { lock.withLock { _calls } }
    /// Every URL exactly as it arrived, login included.
    var urls: [String] { lock.withLock { _urls } }
    var logins: Int { lock.withLock { _logins } }
    var signatureFailures: [String] { lock.withLock { _signatureFailures } }
    func count(_ action: String) -> Int { calls.filter { $0.action == action }.count }
    func last(_ action: String) -> Call? { calls.last { $0.action == action } }

    /// Answer `action` with this payload wrapped in a success envelope.
    func respond(_ action: String, dat: String) { lock.withLock { _responses[action] = Fixtures.envelope(dat); _errors[action] = nil } }
    /// Answer `action` with these exact bytes.
    func respond(_ action: String, body: Data) { lock.withLock { _responses[action] = body; _errors[action] = nil } }
    /// Answer `action` with an API error envelope.
    func fail(_ action: String, code: Int, desc: String) { respond(action, body: Fixtures.failure(code, desc)) }
    /// Fail the transport itself for `action`.
    func breakTransport(_ action: String, with error: Error) { lock.withLock { _errors[action] = error } }
    /// Answer logins with these bytes instead of a new session. Nil restores normal logins.
    func setLoginAnswer(_ body: Data?) { lock.withLock { _loginAnswer = body } }
    /// A hook that sees every data request first; return nil to fall through to `responses`.
    func setResponder(_ responder: (@Sendable (_ action: String, _ parameters: [String: String]) -> Data?)?) {
        lock.withLock { _responder = responder }
    }
    /// Make the cloud accept a token it did not hand out through `authSource` (a session from an earlier run).
    func issue(token: String, secret: String) { lock.withLock { _issued[token] = secret } }
    func revoke(_ token: String) { lock.withLock { _ = _revoked.insert(token) } }
    func revokeAll() { lock.withLock { _revoked.formUnion(_issued.keys) } }

    // MARK: Transport

    func get(_ url: URL) async throws -> (status: Int, body: Data) {
        try lock.withLock { try answer(url) }
    }

    private func answer(_ url: URL) throws -> (status: Int, body: Data) {
        let text = url.absoluteString
        _urls.append(text)
        guard let mark = text.firstIndex(of: "?") else { return (400, Data()) }
        let query = String(text[text.index(after: mark)...])
        var parameters: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parameters[String(parts[0])] == nil { parameters[String(parts[0])] = parts.count > 1 ? String(parts[1]) : "" }
        }
        let action = parameters["action"] ?? ""
        let salt = parameters["salt"] ?? ""
        let sign = parameters["sign"] ?? ""
        let sent = query.range(of: "&action=").map { String(query[$0.upperBound...]) } ?? ""

        if action == "authSource" {
            _logins += 1
            _calls.append(Call(action: action, query: "", token: nil))
            guard sign == DessSigning.loginSign(profile: profile, username: user, password: password, salt: salt) else {
                _signatureFailures.append(action)
                return (200, Fixtures.failure(4, "ERR_SIGN"))
            }
            if let _loginAnswer { return (200, _loginAnswer) }
            let token = "token-\(_logins)"
            let secret = "secret-\(_logins)"
            _issued[token] = secret
            return (200, Fixtures.envelope(#"{"secret":"\#(secret)","token":"\#(token)","expire":604800,"usr":"x","role":0,"uid":1}"#))
        }

        let token = parameters["token"] ?? ""
        _calls.append(Call(action: action, query: sent, token: token))
        guard let secret = _issued[token], !_revoked.contains(token) else {
            return (200, Fixtures.failure(10, "ERR_NO_AUTH"))
        }
        guard sign == DessSigning.sha1Hex(salt + secret + token + "&action=" + sent) else {
            _signatureFailures.append(action)
            return (200, Fixtures.failure(4, "ERR_SIGN"))
        }
        if let error = _errors[action] { throw error }
        if let body = _responder?(action, parameters) { return (200, body) }
        if let body = _responses[action] { return (200, body) }
        return (200, Fixtures.failure(8, "ERR_FORBIDDEN(can not found action: \(action))"))
    }
}

extension FakeCloud {
    /// A cloud that answers every query the service sends with the captured fixtures.
    static func withFixtures(config: InverterConfig) -> FakeCloud {
        let cloud = FakeCloud(config: config)
        cloud.respond("webQueryDeviceEs", dat: Fixtures.devicesEs)
        cloud.respond("queryDevices", dat: Fixtures.devices)
        cloud.respond("queryDeviceLastData", dat: Fixtures.lastData)
        cloud.respond("queryDeviceWarning", dat: Fixtures.warnings)
        cloud.respond("queryPlants", dat: Fixtures.plants)
        cloud.respond("webQueryCollectorsEs", dat: Fixtures.collectors)
        cloud.respond("queryDeviceDataOneDay", dat: Fixtures.dayCurve)
        return cloud
    }
}

/// Holds callers back until it is opened. Lets a test line requests up so that they really overlap.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var waiters: Int { lock.withLock { waiting.count } }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let pass: Bool = lock.withLock {
                if isOpen { return true }
                waiting.append(continuation)
                return false
            }
            if pass { continuation.resume() }
        }
    }

    func open() {
        let released: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { waiting = [] }
            return waiting
        }
        released.forEach { $0.resume() }
    }

    /// Waits (up to two seconds) until `count` callers are held.
    func waitForWaiters(_ count: Int) async {
        for _ in 0..<400 where waiters < count {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// The fake cloud behind gates: a login waits at `loginGate` and every other request at `dataGate`
/// (when one is given) before it is answered. The fake itself answers instantly, which never
/// leaves a login or a request "in flight" for others to run into.
struct SlowCloud: HTTPTransport {
    let inner: FakeCloud
    var loginGate: Gate?
    var dataGate: Gate?

    func get(_ url: URL) async throws -> (status: Int, body: Data) {
        let isLogin = url.absoluteString.contains("&action=authSource&")
        if let gate = isLogin ? loginGate : dataGate { await gate.wait() }
        return try await inner.get(url)
    }
}

enum TestAccount {
    /// Made up. Not the real account.
    static let config = InverterConfig(profile: .dessmonitor, user: "tester@example.com", password: "made-up-password")
}

/// A scratch directory per test, removed afterwards.
class ScratchTestCase: XCTestCase {
    private(set) var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("InverterCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    var sessionFile: URL { scratch.appendingPathComponent("InverterBar/session.json") }
    var store: SessionStore { SessionStore(fileURL: sessionFile) }

    func write(_ text: String, to name: String = ".env") throws -> String {
        let url = scratch.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

func assertThrows<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line,
                     _ check: (Error) -> Void) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        check(error)
    }
}
