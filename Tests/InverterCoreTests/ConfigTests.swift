import XCTest
@testable import InverterCore

final class ConfigTests: ScratchTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "InverterCoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    // MARK: Saving the account

    func testSaveCreatesPrivateFileThatLoadsBack() throws {
        let path = scratch.appendingPathComponent("new/dir/.env").path
        try InverterConfig.save(app: "dessmonitor", user: "me@example.com", password: "p=w #1", path: path)
        XCTAssertEqual(try permissions(of: URL(fileURLWithPath: path)), 0o600)
        let config = try InverterConfig.load(path: path, environment: [:], defaults: defaults)
        XCTAssertEqual(config.user, "me@example.com")
        XCTAssertEqual(config.password, "p=w #1")
        XCTAssertEqual(config.profile.name, "dessmonitor")
    }

    func testSaveReplacesAccountButKeepsOtherLines() throws {
        let path = try write("# mine\nSHINEMONITOR_USER=old\nSHINEMONITOR_PN=PN123\nSHINEMONITOR_PASSWORD=old\n")
        try InverterConfig.save(app: "watchpower", user: "new", password: "secret", path: path)
        let values = InverterConfig.parseEnv(try String(contentsOfFile: path, encoding: .utf8))
        XCTAssertEqual(values["SHINEMONITOR_USER"], "new")
        XCTAssertEqual(values["SHINEMONITOR_PASSWORD"], "secret")
        XCTAssertEqual(values["SHINEMONITOR_APP"], "watchpower")
        XCTAssertEqual(values["SHINEMONITOR_PN"], "PN123")
    }

    func testSignOutRemovesAccountAndSession() throws {
        let path = try write("# mine\nSHINEMONITOR_USER=a\nSHINEMONITOR_PASSWORD=b\nSHINEMONITOR_APP=watchpower\nSHINEMONITOR_PN=P\nOTHER=keep\n")
        try FileManager.default.createDirectory(at: sessionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".write(to: sessionFile, atomically: true, encoding: .utf8)
        try InverterConfig.signOut(path: path, sessionStore: store, historyStore: .memoryOnly)
        let values = InverterConfig.parseEnv(try String(contentsOfFile: path, encoding: .utf8))
        XCTAssertEqual(values, ["OTHER": "keep"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile.path))
    }

    func testSignOutDeletesAnAccountOnlyFile() throws {
        let path = try write("SHINEMONITOR_USER=a\nSHINEMONITOR_PASSWORD=b\n")
        try InverterConfig.signOut(path: path, sessionStore: store, historyStore: .memoryOnly)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    // MARK: Env file parsing (same rules as loadEnvFile() in the Node client)

    func testParseEnvFollowsTheNodeLoader() {
        let text = [
            "# a comment",
            "",
            "   # an indented comment",
            "SHINEMONITOR_USER=someone@example.com",
            "  SHINEMONITOR_APP =  DessMonitor  ",
            "SHINEMONITOR_PASSWORD=\"pass word=with#stuff\"",
            "SINGLE='quoted value'",
            "MISMATCHED=\"left only",
            "EMPTY=",
            "EQUALS=a=b=c",
            "no equals sign on this line",
            "SHINEMONITOR_USER=second definition loses",
            "TRAILING=value # this is not treated as a comment",
            "LONE=\"",
            "export EXPORTED=1",
        ].joined(separator: "\n")

        let values = InverterConfig.parseEnv(text)
        XCTAssertEqual(values["SHINEMONITOR_USER"], "someone@example.com")
        XCTAssertEqual(values["SHINEMONITOR_APP"], "DessMonitor")
        XCTAssertEqual(values["SHINEMONITOR_PASSWORD"], "pass word=with#stuff")
        XCTAssertEqual(values["SINGLE"], "quoted value")
        XCTAssertEqual(values["MISMATCHED"], "\"left only")
        XCTAssertEqual(values["EMPTY"], "")
        XCTAssertEqual(values["EQUALS"], "a=b=c")
        XCTAssertEqual(values["TRAILING"], "value # this is not treated as a comment")
        XCTAssertEqual(values["LONE"], "")
        XCTAssertEqual(values["export EXPORTED"], "1", "the Node loader has no export handling either")
        XCTAssertNil(values["no equals sign on this line"])
        XCTAssertEqual(values.count, 10)
    }

    func testParseEnvHandlesWindowsLineEndingsAndByteOrderMark() {
        let values = InverterConfig.parseEnv("\u{FEFF}A=1\r\nB='two'\r\n\r\n#c\r\nC=3")
        XCTAssertEqual(values, ["A": "1", "B": "two", "C": "3"])
    }

    // MARK: Profiles

    func testProfileSelectionMatchesTheNodeClient() {
        XCTAssertEqual(CloudProfile.named(nil), .watchpower, "same default as the JS")
        XCTAssertEqual(CloudProfile.named(""), .watchpower)
        XCTAssertEqual(CloudProfile.named("nonsense"), .watchpower)
        XCTAssertEqual(CloudProfile.named("watchpower"), .watchpower)
        XCTAssertEqual(CloudProfile.named("solarpower"), .solarpower)
        XCTAssertEqual(CloudProfile.named("dessmonitor"), .dessmonitor)
        XCTAssertEqual(CloudProfile.named("DessMonitor"), .dessmonitor, "the JS lowercases the name")
    }

    func testProfilesCarryTheAppIdentitiesAndCurrentHosts() {
        XCTAssertEqual(CloudProfile.all.map(\.name), ["watchpower", "solarpower", "dessmonitor"])
        XCTAssertEqual(CloudProfile.watchpower.appID, "wifiapp.volfw.watchpower")
        XCTAssertEqual(CloudProfile.watchpower.appVersion, "1.0.6.3")
        XCTAssertEqual(CloudProfile.watchpower.baseURL, "https://web.dessmonitor.com/public/")
        XCTAssertEqual(CloudProfile.solarpower.appID, "com.voltronicpower.solarpower")
        XCTAssertEqual(CloudProfile.solarpower.baseURL, "http://android.shinemonitor.com/public/")
        XCTAssertEqual(CloudProfile.dessmonitor.appID, "wifiapp.volfw.watchpower")
        XCTAssertEqual(CloudProfile.dessmonitor.appVersion, "1.4.6.1")
        XCTAssertEqual(CloudProfile.dessmonitor.baseURL, "https://web.dessmonitor.com/public/")
        for profile in CloudProfile.all {
            XCTAssertEqual(profile.companyKey, "bnrl_frRFjEz8Mkn")
            XCTAssertEqual(profile.source, 1)
            XCTAssertEqual(profile.appClient, "android")
            XCTAssertEqual(profile.locale, "en_US")
        }
    }

    // MARK: Loading

    func testLoadsTheAccountFromAFile() throws {
        let path = try write("""
        # account
        SHINEMONITOR_USER=someone@example.com
        SHINEMONITOR_PASSWORD='made up'
        SHINEMONITOR_APP=dessmonitor
        SHINEMONITOR_PN=W0000000000000
        SHINEMONITOR_SN=00000000000000
        """)
        let config = try InverterConfig.load(path: path, environment: [:], defaults: defaults)
        XCTAssertEqual(config.profile, .dessmonitor)
        XCTAssertEqual(config.user, "someone@example.com")
        XCTAssertEqual(config.password, "made up")
        XCTAssertEqual(config.collectorPN, "W0000000000000")
        XCTAssertEqual(config.inverterSN, "00000000000000")
        XCTAssertEqual(config.sourcePath, path)
    }

    func testOptionalKeysDefaultLikeTheNodeClient() throws {
        let path = try write("SHINEMONITOR_USER=u\nSHINEMONITOR_PASSWORD=p\n")
        let config = try InverterConfig.load(path: path, environment: [:], defaults: defaults)
        XCTAssertEqual(config.profile, .watchpower)
        XCTAssertNil(config.collectorPN, "no serial is baked into the app; the first device is used")
        XCTAssertNil(config.inverterSN)
    }

    func testBaseURLAndSourceOverrides() throws {
        let path = try write("""
        SHINEMONITOR_USER=u
        SHINEMONITOR_PASSWORD=p
        SHINEMONITOR_APP=dessmonitor
        SHINEMONITOR_BASE_URL=https://example.invalid/public/
        SHINEMONITOR_SOURCE=7
        """)
        let config = try InverterConfig.load(path: path, environment: [:], defaults: defaults)
        XCTAssertEqual(config.profile.name, "dessmonitor")
        XCTAssertEqual(config.profile.baseURL, "https://example.invalid/public/")
        XCTAssertEqual(config.profile.source, 7)
    }

    func testProcessEnvironmentWinsOverTheFile() throws {
        let path = try write("SHINEMONITOR_USER=file-user\nSHINEMONITOR_PASSWORD=file-pass\nSHINEMONITOR_APP=solarpower\n")
        let config = try InverterConfig.load(path: path, environment: ["SHINEMONITOR_USER": "env-user", "SHINEMONITOR_APP": "dessmonitor"],
                                             defaults: defaults)
        XCTAssertEqual(config.user, "env-user")
        XCTAssertEqual(config.password, "file-pass")
        XCTAssertEqual(config.profile, .dessmonitor)
    }

    func testMissingFileIsATypedErrorThatNamesThePath() {
        let path = scratch.appendingPathComponent("nope/.env").path
        XCTAssertThrowsError(try InverterConfig.load(path: path, environment: [:], defaults: defaults)) { error in
            XCTAssertEqual(error as? InverterConfigError, .fileNotFound(path: path))
            XCTAssertTrue(error.localizedDescription.contains(path))
            XCTAssertTrue(error.localizedDescription.contains("INVERTERBAR_ENV"))
        }
    }

    func testMissingFileIsFineWhenTheEnvironmentCarriesTheAccount() throws {
        let path = scratch.appendingPathComponent("nope/.env").path
        let config = try InverterConfig.load(path: path, environment: ["SHINEMONITOR_USER": "u", "SHINEMONITOR_PASSWORD": "p"],
                                             defaults: defaults)
        XCTAssertEqual(config.user, "u")
    }

    func testMissingKeyIsATypedErrorThatNamesTheKeyAndPathButNoSecret() throws {
        let path = try write("SHINEMONITOR_USER=someone@example.com\nSHINEMONITOR_PASSWORD=\nSHINEMONITOR_APP=dessmonitor\n")
        XCTAssertThrowsError(try InverterConfig.load(path: path, environment: [:], defaults: defaults)) { error in
            XCTAssertEqual(error as? InverterConfigError, .missingKeys(keys: ["SHINEMONITOR_PASSWORD"], path: path))
            XCTAssertTrue(error.localizedDescription.contains(path))
            XCTAssertTrue(error.localizedDescription.contains("SHINEMONITOR_PASSWORD"))
            XCTAssertFalse(error.localizedDescription.contains("someone@example.com"))
        }

        let empty = try write("# nothing here\n", to: "empty.env")
        XCTAssertThrowsError(try InverterConfig.load(path: empty, environment: [:], defaults: defaults)) { error in
            XCTAssertEqual(error as? InverterConfigError,
                           .missingKeys(keys: ["SHINEMONITOR_USER", "SHINEMONITOR_PASSWORD"], path: empty))
        }
    }

    // MARK: Path resolution

    func testPathResolutionOrder() {
        let home = NSHomeDirectory()
        let standard = home + "/.config/inverterbar/.env", legacy = home + "/Documents/inverter-control/.env"
        // With neither file present the standard place is named, so the error points a new user there.
        XCTAssertEqual(InverterConfig.resolvePath(nil, environment: [:], defaults: defaults, fileExists: { _ in false }), standard)
        // Someone who already has the Node project's file keeps using it...
        XCTAssertEqual(InverterConfig.resolvePath(nil, environment: [:], defaults: defaults, fileExists: { $0 == legacy }), legacy)
        // ...until they create the standard one, which then wins.
        XCTAssertEqual(InverterConfig.resolvePath(nil, environment: [:], defaults: defaults, fileExists: { _ in true }), standard)

        defaults.set("/from/defaults/.env", forKey: "envPath")
        XCTAssertEqual(InverterConfig.resolvePath(nil, environment: [:], defaults: defaults), "/from/defaults/.env")

        let environment = ["INVERTERBAR_ENV": "/from/environment/.env"]
        XCTAssertEqual(InverterConfig.resolvePath(nil, environment: environment, defaults: defaults), "/from/environment/.env")

        XCTAssertEqual(InverterConfig.resolvePath("/explicit/.env", environment: environment, defaults: defaults), "/explicit/.env")
    }

    func testPathResolutionSkipsEmptyValuesAndExpandsTilde() {
        defaults.set("  ", forKey: "envPath")
        XCTAssertEqual(InverterConfig.resolvePath("", environment: ["INVERTERBAR_ENV": ""], defaults: defaults, fileExists: { _ in false }),
                       NSHomeDirectory() + "/.config/inverterbar/.env")
        XCTAssertEqual(InverterConfig.resolvePath("~/somewhere/.env", environment: [:], defaults: defaults),
                       NSHomeDirectory() + "/somewhere/.env")
    }

    // MARK: Nothing prints the account

    func testDescriptionsNeverShowTheAccount() {
        let config = InverterConfig(profile: .dessmonitor, user: "someone@example.com", password: "hunter2-made-up",
                                    collectorPN: "W0000000000000", inverterSN: "00000000000000", sourcePath: "/x/.env")
        var dumped = ""
        dump(config, to: &dumped)
        for text in [String(describing: config), String(reflecting: config), "\(config)", dumped] {
            XCTAssertFalse(text.contains("hunter2"), text)
            XCTAssertFalse(text.contains("someone@example.com"), text)
        }
        XCTAssertTrue(String(describing: config).contains("dessmonitor"))
    }
}
