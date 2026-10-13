import CryptoKit
import Foundation

// READ-ONLY CLIENT. The Node client's device-control call and its two control-field queries are
// deliberately not ported: nothing here can change an inverter setting.
//
// That is enforced twice. At run time, `DessMonitorClient` signs only the actions listed in
// `DessMonitorClient.readOnlyActions` and refuses everything else before anything is sent
// (`DessReadOnly.check`). At test time, ReadOnlyGuardTests fails if a control action name ever
// appears in the sources.

// MARK: - Read-only allow-list

/// The gate every data request passes before it is signed.
public enum DessReadOnly {
    /// Every action this app may send. Each one only reads. Adding a name here is a deliberate
    /// act that ReadOnlyGuardTests has to be changed to accept.
    public static let actions: Set<String> = [
        "webQueryDeviceEs", "queryDevices", "queryDeviceLastData", "queryDeviceWarning",
        "queryPlants", "webQueryCollectorsEs", "queryDeviceDataOneDay",
    ]

    /// Parameters the client adds itself. An action string must not bring its own, and above all
    /// not a second `action`, which is how a write could otherwise ride along with a query.
    static let reservedParameters: Set<String> = ["action", "sign", "salt", "token"]

    /// Throws unless `action` is one allow-listed query followed by plain `key=value` parameters.
    /// `action` is the action name plus its parameters, e.g. `queryPlants&page=0&pagesize=20`.
    public static func check(_ action: String) throws {
        let parts = action.split(separator: "&", omittingEmptySubsequences: false)
        let name = String(parts.first ?? "")
        guard actions.contains(name) else {
            throw DessMonitorError.actionNotAllowed(printable(name))
        }
        for part in parts.dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[0].isEmpty, pair[0].utf8.allSatisfy(isKeyByte) else {
                throw DessMonitorError.invalidRequest(action: name)
            }
            guard !reservedParameters.contains(pair[0].lowercased()) else {
                throw DessMonitorError.actionNotAllowed(printable(name))
            }
            // Serial numbers, dates and locale codes. Nothing that needs escaping, so the string
            // that is signed is byte for byte the string that is sent.
            guard pair[1].utf8.allSatisfy(isValueByte) else {
                throw DessMonitorError.invalidRequest(action: name)
            }
        }
    }

    private static func isKeyByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F
    }

    private static func isValueByte(_ byte: UInt8) -> Bool {
        isKeyByte(byte) || byte == 0x2D || byte == 0x2E || byte == 0x3A   // - . :
    }

    /// A refused name is shown in an error, so only letters and digits of it are kept.
    static func printable(_ name: String) -> String {
        let kept = name.unicodeScalars.filter { $0.isASCII && isKeyByte(UInt8($0.value)) }.prefix(40)
        return kept.isEmpty ? "(unnamed)" : String(String.UnicodeScalarView(kept))
    }
}

// MARK: - Signing

/// The vendor's request signing, ported byte for byte from `lib/shinemonitor.js`.
///
/// Two rules matter and are easy to get wrong:
/// - Login signs the action string with the RAW username, but sends it `encodeURIComponent`-encoded.
/// - A signed request signs `&action=...` exactly as it is sent, and does not append the app suffix.
public enum DessSigning {
    /// Lowercase hex SHA-1 of the UTF-8 bytes. SHA-1 is what the vendor API requires.
    public static func sha1Hex(_ text: String) -> String {
        var hex = ""
        hex.reserveCapacity(40)
        for byte in Insecure.SHA1.hash(data: Data(text.utf8)) {
            hex.unicodeScalars.append(hexDigits[Int(byte >> 4)])
            hex.unicodeScalars.append(hexDigits[Int(byte & 0x0F)])
        }
        return hex
    }

    /// JavaScript's `encodeURIComponent`: everything except `A-Z a-z 0-9 - _ . ! ~ * ' ( )` is
    /// percent-encoded as UTF-8 with uppercase hex.
    public static func encodeURIComponent(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            if unreserved.contains(byte) {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                out.unicodeScalars.append("%")
                out.unicodeScalars.append(upperHexDigits[Int(byte >> 4)])
                out.unicodeScalars.append(upperHexDigits[Int(byte & 0x0F)])
            }
        }
        return out
    }

    /// `String(Date.now())`: whole milliseconds since 1970.
    public static func salt(at date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 * 1000).rounded(.down)))
    }

    /// The app identification appended to the login action (and only to the login action).
    public static func suffix(_ profile: CloudProfile) -> String {
        "&source=\(profile.source)"
            + "&_app_client_=\(profile.appClient)"
            + "&_app_id_=\(profile.appID)"
            + "&_app_version_=\(profile.appVersion)"
            + "&lang=\(profile.locale)"
    }

    public static func loginSign(profile: CloudProfile, username: String, password: String, salt: String) -> String {
        let actionRaw = "&action=authSource&usr=\(username)&company-key=\(profile.companyKey)" + suffix(profile)
        return sha1Hex(salt + sha1Hex(password) + actionRaw)
    }

    public static func loginURLString(profile: CloudProfile, username: String, password: String, salt: String) -> String {
        let action = "&action=authSource&usr=\(encodeURIComponent(username))&company-key=\(profile.companyKey)" + suffix(profile)
        let sign = loginSign(profile: profile, username: username, password: password, salt: salt)
        return "\(profile.baseURL)?sign=\(sign)&salt=\(salt)\(action)"
    }

    /// `action` is the action name plus its parameters, e.g. `queryPlants&page=0&pagesize=20`.
    public static func requestSign(secret: String, token: String, action: String, salt: String) -> String {
        sha1Hex(salt + secret + token + "&action=\(action)")
    }

    public static func requestURLString(profile: CloudProfile, secret: String, token: String, action: String, salt: String) -> String {
        let sign = requestSign(secret: secret, token: token, action: action, salt: salt)
        return "\(profile.baseURL)?sign=\(sign)&salt=\(salt)&token=\(token)&action=\(action)"
    }

    private static let hexDigits = Array("0123456789abcdef".unicodeScalars)
    private static let upperHexDigits = Array("0123456789ABCDEF".unicodeScalars)
    private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()".utf8)
}

// MARK: - Errors

public enum DessMonitorError: Error, Equatable, Sendable {
    /// No usable session and no username or password to make one.
    case missingCredentials
    /// The vendor refused the login (wrong password, unknown user, locked account).
    case loginRejected(code: Int, desc: String)
    /// The vendor answered a signed request with a non-zero `err`.
    case api(action: String, code: Int, desc: String)
    case timedOut
    case offline
    case network(code: Int, message: String)
    /// The answer was not the JSON envelope the API always sends.
    case badResponse(action: String, status: Int)
    case invalidRequest(action: String)
    /// The action is not one of the read-only queries this app sends. Nothing was sent.
    case actionNotAllowed(String)

    /// The session is no longer accepted: `ERR_NO_AUTH` (0x000A, "not authenticated"; seen live
    /// for a refused token) or `ERR_SIGN` (0x0004, "signature cannot be verified": the secret no
    /// longer matches). Numbers from the vendor's error table, api.dessmonitor.com chapter1/errCode.
    /// `ERR_NO_PERMISSION` (0x000B) is deliberately not one: a new login cannot grant a permission.
    public var isAuthFailure: Bool {
        guard case .api(_, let code, let desc) = self else { return false }
        if code == 4 || code == 10 { return true }
        let upper = desc.uppercased()
        return upper.contains("NO_AUTH") || upper.contains("ERR_SIGN") || upper.contains("TOKEN")
    }

    /// `ERR_NO_RECORD` (0x000C): the query is fine, there is just nothing stored for it yet.
    public var isNoRecord: Bool {
        guard case .api(_, let code, let desc) = self else { return false }
        return code == 12 || desc.uppercased().contains("NO_RECORD")
    }
}

extension DessMonitorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "No saved session, and the account file has no username or password."
        case .loginRejected(let code, let desc):
            return "The inverter cloud refused the login (\(desc.isEmpty ? "error \(code)" : desc))."
        case .api(let action, let code, let desc):
            return "The inverter cloud answered \(action) with \(desc.isEmpty ? "error \(code)" : desc)."
        case .timedOut:
            return "The inverter cloud did not answer in time."
        case .offline:
            return "No connection to the inverter cloud."
        case .network(_, let message):
            return "Could not reach the inverter cloud: \(message)"
        case .badResponse(let action, let status):
            return "The inverter cloud sent an unreadable answer to \(action) (HTTP \(status))."
        case .invalidRequest(let action):
            return "Could not build the request for \(action)."
        case .actionNotAllowed(let action):
            return "InverterBar only reads from the inverter. It does not send \(action)."
        }
    }
}

// MARK: - Transport

/// One HTTP GET. A protocol so the client can be exercised in tests without the network.
public protocol HTTPTransport: Sendable {
    func get(_ url: URL) async throws -> (status: Int, body: Data)
}

/// URLSession with an ephemeral configuration (no cookies, no cache, nothing on disk) and a 20 s timeout.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 20) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    public func get(_ url: URL) async throws -> (status: Int, body: Data) {
        let (data, response) = try await session.data(from: url)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

// MARK: - Session

/// What a login returns, kept between launches so the app does not log in every time.
struct DessSession: Codable, Sendable, Equatable {
    var profile: String
    var baseURL: String
    var secret: String
    var token: String
    /// Milliseconds since 1970, like the Node client's `expireAt`.
    var expireAt: Double
    /// Fingerprint of profile + username, so a saved session is never used for another account.
    var account: String
    /// Milliseconds since 1970 when this login happened.
    var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case profile, secret, token, expireAt, account, createdAt
        case baseURL = "base_url"
    }

    /// Valid until one minute before the vendor's expiry, as in the Node client.
    func isUsable(for profile: CloudProfile, account: String, at date: Date) -> Bool {
        self.profile == profile.name && baseURL == profile.baseURL && self.account == account
            && !secret.isEmpty && !token.isEmpty
            && date.timeIntervalSince1970 * 1000 <= expireAt - 60_000
    }

    static func fingerprint(profile: CloudProfile, user: String) -> String {
        let digest = SHA256.hash(data: Data("\(profile.name)\n\(user)".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

extension DessSession: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "DessSession(profile: \(profile), secret: <redacted>, token: <redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["profile": profile], displayStyle: .struct) }
}

/// Where the session is kept: `~/Library/Application Support/InverterBar/session.json`, mode 0600.
/// The Node project's own `.session.json` is never read or written.
public struct SessionStore: Sendable {
    public let fileURL: URL?

    public init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    public static let standard: SessionStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return SessionStore(fileURL: base.appendingPathComponent("InverterBar", isDirectory: true)
            .appendingPathComponent("session.json", isDirectory: false))
    }()

    /// Keeps the session in memory only.
    public static let memoryOnly = SessionStore(fileURL: nil)

    func load() -> DessSession? {
        guard let fileURL, let data = FileManager.default.contents(atPath: fileURL.path) else { return nil }
        // If something widened the file's permissions since it was written, close them again.
        if let mode = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.posixPermissions] as? NSNumber,
           mode.intValue & 0o077 != 0 {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
        return try? JSONDecoder().decode(DessSession.self, from: data)
    }

    /// Writes through a 0600 temporary file and renames it over the old one, so the secret is
    /// never on disk with wider permissions and a crash cannot leave half a file.
    func save(_ session: DessSession) throws {
        guard let fileURL else { return }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // createDirectory leaves a folder that already exists as it is; make sure of it.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(session)

        let temporary = directory.appendingPathComponent(".session-\(UUID().uuidString).tmp", isDirectory: false)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        guard rename(temporary.path, fileURL.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - Client

/// Signed, read-only access to the DessMonitor / ShineMonitor cloud.
///
/// An actor so that several requests running at once share one login: if the saved session has
/// been revoked, the first failure logs in again and the others wait for that login.
public actor DessMonitorClient {
    public nonisolated let profile: CloudProfile

    private let user: String
    private let password: String
    private let account: String
    private let store: SessionStore
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date

    private var session: DessSession?
    /// Goes up with every login; lets a failed request tell whether someone already renewed.
    private var sessionSerial = 0
    private var loginTask: Task<DessSession, Error>?
    /// After the vendor refuses the credentials, do not ask again for a while: a minute at first,
    /// then twice as long after each further refusal, up to 32 minutes. An app that polls would
    /// otherwise send a wrong password every minute all day, which is how accounts get frozen
    /// (`ERR_USR_DISABLED`). Cleared by the next login that works.
    private var loginRefusal: (until: Date, error: DessMonitorError, count: Int)?
    /// Actions the cloud refused even on a brand-new session, by action name. See `noteRefusal`.
    private var refusals: [String: (count: Int, retryAfter: Date)] = [:]

    /// A request that fails with an auth error on a session younger than this is not retried
    /// with yet another login, so a persistent signing problem cannot turn into a login loop.
    static let minimumSecondsBetweenLogins: TimeInterval = 60

    /// The only actions this client will sign. All of them read.
    public static let readOnlyActions = DessReadOnly.actions

    public init(config: InverterConfig,
                sessionStore: SessionStore = .standard,
                transport: any HTTPTransport = URLSessionTransport(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        profile = config.profile
        user = config.user
        password = config.password
        account = DessSession.fingerprint(profile: config.profile, user: config.user)
        store = sessionStore
        self.transport = transport
        self.now = now
    }

    /// Sends one signed read request and returns its `dat`. `action` is the action name plus its
    /// parameters, e.g. `queryPlants&page=0&pagesize=20&i18n=en_US`.
    ///
    /// If a session that was already in hand (from disk or from an earlier login) is refused,
    /// this logs in again once and retries once.
    ///
    /// Only the queries in `readOnlyActions` are accepted. Anything else throws
    /// `DessMonitorError.actionNotAllowed` before a login or any other request is made.
    public func request(_ action: String) async throws -> JSONValue {
        try DessReadOnly.check(action)
        let name = Self.actionName(action)
        let current = try await activeSession()
        do {
            let dat = try await send(action, with: current.session)
            refusals[name] = nil
            return dat
        } catch let error as DessMonitorError where error.isAuthFailure {
            if current.fresh {
                // Refused on a session made for this very request: another login cannot help.
                noteRefusal(of: name)
                throw error
            }
            if let refusal = refusals[name], now() < refusal.retryAfter { throw error }
            guard let renewed = try await renewSession(afterFailureOf: current.serial) else { throw error }
            do {
                let dat = try await send(action, with: renewed)
                refusals[name] = nil
                return dat
            } catch let second as DessMonitorError where second.isAuthFailure {
                noteRefusal(of: name)
                throw second
            }
        }
    }

    /// The cloud refused `name` even on a brand-new session, so the session is not what is wrong
    /// (the account may simply not be allowed that query). Wait longer each time before spending
    /// another login on it: 1, 2, 4 ... 32 minutes. Without this an app that polls would log in
    /// once a minute for as long as it runs.
    private func noteRefusal(of name: String) {
        let count = (refusals[name]?.count ?? 0) + 1
        refusals[name] = (count, now().addingTimeInterval(Self.renewalBackoff(afterRefusals: count)))
    }

    static func renewalBackoff(afterRefusals count: Int) -> TimeInterval {
        let doublings = Double(min(max(count, 1), 6) - 1)
        return minimumSecondsBetweenLogins * pow(2, doublings)
    }

    // MARK: Session handling

    private func activeSession() async throws -> (session: DessSession, serial: Int, fresh: Bool) {
        if let session, session.isUsable(for: profile, account: account, at: now()) {
            return (session, sessionSerial, false)
        }
        if let loginTask {
            // A login is already running (first use, or a renewal). Wait for it rather than
            // picking the old session back up from disk.
            let fresh = try await loginTask.value
            return (fresh, sessionSerial, true)
        }
        if let saved = store.load(), saved.isUsable(for: profile, account: account, at: now()) {
            session = saved
            sessionSerial += 1
            return (saved, sessionSerial, false)
        }
        let fresh = try await login()
        return (fresh, sessionSerial, true)
    }

    /// Nil means "do not retry": the refused session is itself brand new.
    private func renewSession(afterFailureOf serial: Int) async throws -> DessSession? {
        if sessionSerial != serial, let session, session.isUsable(for: profile, account: account, at: now()) {
            return session   // another request already logged in again
        }
        if loginTask == nil, let session {
            // `abs`: a login stamped in the future (the Mac's clock was set back) must not look
            // forever young and block every later renewal.
            let ageMs = now().timeIntervalSince1970 * 1000 - session.createdAt
            if abs(ageMs) < Self.minimumSecondsBetweenLogins * 1000 { return nil }
        }
        session = nil
        store.clear()   // the server refused it; do not let the next launch try it again
        return try await login()
    }

    /// Concurrent callers share one login.
    private func login() async throws -> DessSession {
        if let loginTask { return try await loginTask.value }
        let task = Task { try await self.performLogin() }
        loginTask = task
        defer { loginTask = nil }
        return try await task.value
    }

    private func performLogin() async throws -> DessSession {
        guard !user.isEmpty, !password.isEmpty else { throw DessMonitorError.missingCredentials }
        if let refusal = loginRefusal, now() < refusal.until { throw refusal.error }

        let started = now()
        let urlString = DessSigning.loginURLString(profile: profile, username: user, password: password,
                                                   salt: DessSigning.salt(at: started))
        let json = try await fetchJSON(urlString, action: "authSource")
        let code = json["err"]?.intValue ?? -1
        guard code == 0 else {
            // The password, and the hash of it that the login is signed with.
            let hidden = [password, DessSigning.sha1Hex(password)]
            let error = DessMonitorError.loginRejected(code: code, desc: Self.scrub(json["desc"]?.stringValue ?? "", hiding: hidden))
            let count = (loginRefusal?.count ?? 0) + 1
            loginRefusal = (now().addingTimeInterval(Self.renewalBackoff(afterRefusals: count)), error, count)
            throw error
        }
        guard let dat = json["dat"], let secret = dat["secret"]?.nonEmptyString, let token = dat["token"]?.nonEmptyString else {
            throw DessMonitorError.badResponse(action: "authSource", status: 200)
        }
        // `json.dat.expire || 604800` in the Node client: seven days when the field is missing or zero.
        let lifetime = dat["expire"]?.doubleValue.flatMap { $0 > 0 ? $0 : nil } ?? 604_800
        let startedMs = started.timeIntervalSince1970 * 1000
        let fresh = DessSession(profile: profile.name, baseURL: profile.baseURL, secret: secret, token: token,
                                expireAt: startedMs + lifetime * 1000, account: account, createdAt: startedMs)
        session = fresh
        sessionSerial += 1
        loginRefusal = nil
        try? store.save(fresh)   // a session that cannot be saved still works for this run
        return fresh
    }

    // MARK: Wire

    private func send(_ action: String, with session: DessSession) async throws -> JSONValue {
        // The one place a data request is signed, so the read-only gate is checked here as well
        // as on the way in: no future caller inside this file can get round it.
        try DessReadOnly.check(action)
        let name = Self.actionName(action)
        let urlString = DessSigning.requestURLString(profile: profile, secret: session.secret, token: session.token,
                                                     action: action, salt: DessSigning.salt(at: now()))
        let json = try await fetchJSON(urlString, action: name)
        let code = json["err"]?.intValue ?? -1
        guard code == 0 else {
            let desc = Self.scrub(json["desc"]?.stringValue ?? "", hiding: [session.token, session.secret])
            throw DessMonitorError.api(action: name, code: code, desc: desc)
        }
        return json["dat"] ?? .null
    }

    private func fetchJSON(_ urlString: String, action: String) async throws -> JSONValue {
        // The URL carries the token and the signature. It must never reach an error or a log,
        // which is why transport errors are rebuilt below instead of being passed on.
        guard let url = URL(string: urlString, encodingInvalidCharacters: true) else {
            throw DessMonitorError.invalidRequest(action: action)
        }
        let response: (status: Int, body: Data)
        do {
            response = try await transport.get(url)
        } catch {
            throw Self.safeError(for: error)
        }
        guard let json = try? JSONValue.parse(response.body), json.objectValue != nil else {
            throw DessMonitorError.badResponse(action: action, status: response.status)
        }
        return json
    }

    static func actionName(_ action: String) -> String {
        String(action.prefix { $0 != "&" })
    }

    /// A transport failure with the request URL stripped: `URLError` keeps the failing URL in
    /// its user info, and that URL holds the session token.
    static func safeError(for error: Error) -> Error {
        if error is CancellationError { return error }
        if let known = error as? DessMonitorError { return known }
        guard let urlError = error as? URLError else {
            return DessMonitorError.network(code: (error as NSError).code, message: "The request failed.")
        }
        switch urlError.code {
        case .cancelled:
            return CancellationError()
        case .timedOut:
            return DessMonitorError.timedOut
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
            return DessMonitorError.offline
        default:
            return DessMonitorError.network(code: urlError.code.rawValue, message: scrub(urlError.localizedDescription, hiding: []))
        }
    }

    /// Server text is shown to the user, so anything that could be a secret or a URL is removed first.
    static func scrub(_ text: String, hiding secrets: [String]) -> String {
        var out = text
        for secret in secrets where !secret.isEmpty {
            out = out.replacingOccurrences(of: secret, with: "<redacted>")
        }
        out = out.replacingOccurrences(of: #"https?://\S+"#, with: "<url>", options: .regularExpression)
        return String(out.prefix(200))
    }
}

// The client holds the password and the live session. `dump()` and `Mirror` would otherwise walk
// its stored properties and print both.
extension DessMonitorClient: CustomReflectable {
    public nonisolated var customMirror: Mirror {
        Mirror(self, children: ["profile": profile.name, "account": "<redacted>"], displayStyle: .class)
    }
}
