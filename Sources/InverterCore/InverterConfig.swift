import Foundation

/// Which vendor app the client pretends to be. Same three app identities as the Node client
/// (`lib/shinemonitor.js`); the company key is the vendor app's public key, not an account secret.
public struct CloudProfile: Sendable, Equatable {
    public var name: String
    public var appID: String
    public var appVersion: String
    public var companyKey: String
    public var baseURL: String
    public var source: Int
    public var appClient: String
    public var locale: String

    public init(name: String, appID: String, appVersion: String, companyKey: String, baseURL: String,
                source: Int = 1, appClient: String = "android", locale: String = "en_US") {
        self.name = name; self.appID = appID; self.appVersion = appVersion; self.companyKey = companyKey
        self.baseURL = baseURL; self.source = source; self.appClient = appClient; self.locale = locale
    }

    public static let watchpower = CloudProfile(
        name: "watchpower", appID: "wifiapp.volfw.watchpower", appVersion: "1.0.6.3",
        companyKey: "bnrl_frRFjEz8Mkn", baseURL: "https://web.dessmonitor.com/public/")

    public static let solarpower = CloudProfile(
        name: "solarpower", appID: "com.voltronicpower.solarpower", appVersion: "1.0.6.3",
        companyKey: "bnrl_frRFjEz8Mkn", baseURL: "http://android.shinemonitor.com/public/")

    /// The SolarPower / WatchPower 1.4 phone app talks to DessMonitor.
    public static let dessmonitor = CloudProfile(
        name: "dessmonitor", appID: "wifiapp.volfw.watchpower", appVersion: "1.4.6.1",
        companyKey: "bnrl_frRFjEz8Mkn", baseURL: "https://web.dessmonitor.com/public/")

    public static let all: [CloudProfile] = [.watchpower, .solarpower, .dessmonitor]

    /// Profile for a `SHINEMONITOR_APP` value. Unknown or missing names fall back to
    /// `watchpower`, the same default as the Node client.
    public static func named(_ name: String?) -> CloudProfile {
        let key = (name ?? "").lowercased()
        return all.first { $0.name == key } ?? .watchpower
    }
}

public enum InverterConfigError: Error, Equatable, Sendable {
    case fileNotFound(path: String)
    case unreadable(path: String)
    case missingKeys(keys: [String], path: String)
}

extension InverterConfigError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "No inverter account file at \(path). Point \(InverterConfig.envPathVariable) or the "
                + "\"\(InverterConfig.envPathDefaultsKey)\" default at the .env that holds "
                + "\(InverterConfig.Key.user) and \(InverterConfig.Key.password)."
        case .unreadable(let path):
            return "The inverter account file at \(path) could not be read."
        case .missingKeys(let keys, let path):
            return "\(path) is missing \(keys.joined(separator: " and "))."
        }
    }
}

/// The cloud account, read from an env file. Read-only use: nothing in this package writes
/// an inverter setting.
public struct InverterConfig: Sendable, Equatable {
    public enum Key {
        public static let user = "SHINEMONITOR_USER"
        public static let password = "SHINEMONITOR_PASSWORD"
        public static let app = "SHINEMONITOR_APP"
        public static let pn = "SHINEMONITOR_PN"
        public static let sn = "SHINEMONITOR_SN"
        public static let baseURL = "SHINEMONITOR_BASE_URL"
        public static let source = "SHINEMONITOR_SOURCE"
        static let all = [user, password, app, pn, sn, baseURL, source]
    }

    public static let envPathVariable = "INVERTERBAR_ENV"
    public static let envPathDefaultsKey = "envPath"
    public static let defaultEnvPath = "~/.config/inverterbar/.env"
    /// Also looked in, for people who already keep the account in the inverter-control Node project.
    public static let legacyEnvPath = "~/Documents/inverter-control/.env"

    public var profile: CloudProfile
    public var user: String
    public var password: String
    /// Wi-Fi stick PN to prefer when the account has more than one device. Nil picks the first.
    public var collectorPN: String?
    /// Inverter serial to prefer when the account has more than one device. Nil picks the first.
    public var inverterSN: String?
    /// The env file this was loaded from, for error messages.
    public var sourcePath: String?

    public init(profile: CloudProfile, user: String, password: String,
                collectorPN: String? = nil, inverterSN: String? = nil, sourcePath: String? = nil) {
        self.profile = profile; self.user = user; self.password = password
        self.collectorPN = collectorPN; self.inverterSN = inverterSN; self.sourcePath = sourcePath
    }

    /// Where the account file is: the explicit argument, then `INVERTERBAR_ENV`, then the
    /// `envPath` user default, then `~/.config/inverterbar/.env`. Empty values are skipped.
    /// If that last file is missing and `~/Documents/inverter-control/.env` exists, that one is used.
    public static func resolvePath(_ explicit: String? = nil,
                                   environment: [String: String] = ProcessInfo.processInfo.environment,
                                   defaults: UserDefaults = .standard,
                                   fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
        let candidates = [explicit, environment[envPathVariable], defaults.string(forKey: envPathDefaultsKey)]
        if let chosen = candidates.compactMap({ $0 }).map(jsTrim).first(where: { !$0.isEmpty }) { return expand(chosen) }
        let standard = expand(defaultEnvPath), legacy = expand(legacyEnvPath)
        return !fileExists(standard) && fileExists(legacy) ? legacy : standard
    }

    /// Loads the account. As in the Node loader, a `SHINEMONITOR_*` variable already present in the
    /// process environment wins over the file, and an empty value counts as missing.
    public static func load(path explicit: String? = nil,
                            environment: [String: String] = ProcessInfo.processInfo.environment,
                            defaults: UserDefaults = .standard) throws -> InverterConfig {
        let path = resolvePath(explicit, environment: environment, defaults: defaults)

        var fileValues: [String: String] = [:]
        let fileExists = FileManager.default.fileExists(atPath: path)
        if fileExists {
            guard let data = FileManager.default.contents(atPath: path) else {
                throw InverterConfigError.unreadable(path: path)
            }
            fileValues = parseEnv(String(decoding: data, as: UTF8.self))
        }

        func value(_ key: String) -> String? {
            let raw = environment[key] ?? fileValues[key]
            return (raw?.isEmpty ?? true) ? nil : raw
        }

        let user = value(Key.user)
        let password = value(Key.password)
        guard let user, let password else {
            // The Node loader tolerates a missing file when the environment carries the account;
            // so does this one. Otherwise the missing file is the thing to report.
            guard fileExists else { throw InverterConfigError.fileNotFound(path: path) }
            let missing = [(Key.user, user), (Key.password, password)].filter { $0.1 == nil }.map(\.0)
            throw InverterConfigError.missingKeys(keys: missing, path: path)
        }

        var profile = CloudProfile.named(value(Key.app))
        if let baseURL = value(Key.baseURL) { profile.baseURL = baseURL }
        if let source = value(Key.source).flatMap({ Int($0) }) { profile.source = source }

        return InverterConfig(profile: profile, user: user, password: password,
                              collectorPN: value(Key.pn), inverterSN: value(Key.sn), sourcePath: path)
    }

    /// The file's lines without the given keys, or none if there is no file.
    private static func lines(of path: String, without keys: Set<String>) -> [String] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines).filter { line in
            guard let equals = line.firstIndex(of: "=") else { return true }
            return !keys.contains(jsTrim(String(line[..<equals])))
        }
        while lines.last.map(jsTrim) == "" { lines.removeLast() }
        return lines
    }

    private static func write(_ lines: [String], to path: String) throws {
        try writePrivately(Data((lines.joined(separator: "\n") + "\n").utf8), to: URL(fileURLWithPath: path))
    }

    /// Saves the account to the env file (mode 0600), keeping any other lines in it, such as a device
    /// pick. Writes to `resolvePath()`, so the next `load()` finds it.
    @discardableResult
    public static func save(app: String, user: String, password: String, path explicit: String? = nil) throws -> String {
        let path = resolvePath(explicit)
        let lines = lines(of: path, without: [Key.user, Key.password, Key.app])
            + ["\(Key.user)=\(user)", "\(Key.password)=\(password)", "\(Key.app)=\(app)"]
        try write(lines, to: path)
        return path
    }

    /// Forgets the account: removes it from the env file (the file itself goes if nothing else is in
    /// it) and deletes the saved login session.
    public static func signOut(path explicit: String? = nil, sessionStore: SessionStore = .standard) throws {
        let path = resolvePath(explicit)
        sessionStore.clear()
        let rest = lines(of: path, without: [Key.user, Key.password, Key.app, Key.pn, Key.sn])
        if rest.contains(where: { !jsTrim($0).isEmpty }) {
            try write(rest, to: path)
        } else if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    /// Same rules as `loadEnvFile()` in the Node client: one `KEY=value` per line, blank lines and
    /// lines starting with `#` skipped, lines without `=` skipped, key and value trimmed, one pair
    /// of matching single or double quotes around the value removed, first definition of a key wins.
    /// No `export` prefix and no trailing-comment handling, exactly like the original.
    public static func parseEnv(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        // Swift treats "\r\n" as one Character, so both line endings are covered here.
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let trimmed = jsTrim(String(line))
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = jsTrim(String(trimmed[..<equals]))
            var value = jsTrim(String(trimmed[trimmed.index(after: equals)...]))
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                // JS `slice(1, -1)`: a lone quote character becomes the empty string.
                value = value.count >= 2 ? String(value.dropFirst().dropLast()) : ""
            }
            if values[key] == nil { values[key] = value }
        }
        return values
    }

    /// `String.prototype.trim()`: Unicode white space, line terminators and the byte order mark.
    static func jsTrim(_ text: String) -> String {
        text.trimmingCharacters(in: jsWhitespace)
    }

    private static let jsWhitespace = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
}

// Printing or dumping a config must never show the account.
extension InverterConfig: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "InverterConfig(profile: \(profile.name), account: <redacted>, source: \(sourcePath ?? "none"))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["profile": profile.name, "sourcePath": sourcePath ?? "none"], displayStyle: .struct)
    }
}
