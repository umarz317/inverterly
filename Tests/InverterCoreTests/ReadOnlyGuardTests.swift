import XCTest
@testable import InverterCore

/// The standing rule for this app is "do not write inverter settings". The vendor API can change
/// settings (and delete devices, rename plants, change the password) through actions that are
/// signed exactly like the queries, so the rule is held in two places:
///
/// 1. At run time the client signs only the actions in `DessReadOnly.actions`. These tests prove
///    that everything else is refused before a single request, login included, leaves the Mac.
/// 2. The sources are read here and must not mention a control action at all, even in a comment.
final class ReadOnlyGuardTests: XCTestCase {
    private func makeClient() -> (DessMonitorClient, FakeCloud) {
        let cloud = FakeCloud.withFixtures(config: TestAccount.config)
        let client = DessMonitorClient(config: TestAccount.config, sessionStore: .memoryOnly, transport: cloud,
                                       now: TestClock().reader)
        return (client, cloud)
    }

    // MARK: Run time

    func testTheAllowListIsExactlyTheSevenQueries() {
        XCTAssertEqual(DessReadOnly.actions, ["webQueryDeviceEs", "queryDevices", "queryDeviceLastData", "queryDeviceWarning",
                                              "queryPlants", "webQueryCollectorsEs", "queryDeviceDataOneDay"],
                       "a new action has to be added here on purpose")
        XCTAssertEqual(DessMonitorClient.readOnlyActions, DessReadOnly.actions)
        for action in DessReadOnly.actions {
            XCTAssertTrue(action.lowercased().contains("query"), action)
            XCTAssertFalse(action.lowercased().contains("ctrl"), action)
        }
    }

    func testEveryWriteActionIsRefusedBeforeAnythingIsSent() async throws {
        let (client, cloud) = makeClient()
        // The Node client's write call, its two control-field reads, and a sample of the vendor's
        // other mutating actions. None of them is in the allow-list, so none can be sent.
        let refused = [
            "ctrlDevice&pn=W0000000000000&devcode=2452&devaddr=1&sn=00000000000000&id=bat_charging_current&val=10",
            "queryDeviceCtrlField&pn=W0000000000000&devcode=2452&devaddr=1&sn=00000000000000&i18n=en_US",
            "queryDeviceCtrlValue&pn=W0000000000000&devcode=2452&devaddr=1&sn=00000000000000&i18n=en_US",
            "editDeviceInfo&pn=W0000000000000&alias=x", "delDeviceFromPlant&pn=W0000000000000", "delCollectorFromPlant&pn=W0000000000000",
            "addCollectorToPlant&pn=W0000000000000", "editPlant&pid=1&name=x", "delPlant&pid=1", "updatePassword&newpwd=x",
            "sendCmdToDevice&pn=W0000000000000&cmd=x", "authSource&usr=x", "querySPDeviceLastData&pn=W0000000000000",
            "", "&", "QUERYPLANTS", "queryPlants2", " queryPlants", "queryPlants ", "queryPlants\n&page=0",
        ]
        for action in refused {
            await assertThrows(try await client.request(action)) { error in
                guard case .actionNotAllowed? = error as? DessMonitorError else { return XCTFail("\(action): \(error)") }
                XCTAssertTrue(error.localizedDescription.contains("only reads"), error.localizedDescription)
            }
        }
        XCTAssertEqual(cloud.calls, [], "not even a login")
        XCTAssertEqual(cloud.urls, [])
    }

    func testAnAllowedQueryCannotCarryASecondAction() async throws {
        let (client, cloud) = makeClient()
        // If the server took the last `action` it saw, a query could smuggle a write behind it.
        let smuggled = [
            "queryPlants&action=ctrlDevice&id=x&val=1",
            "queryPlants&page=0&ACTION=ctrlDevice",
            "queryDeviceLastData&pn=W0000000000000&token=other&sn=1",
            "queryDeviceLastData&pn=W0000000000000&sign=abc",
            "queryDeviceLastData&pn=W0000000000000&salt=1",
        ]
        for action in smuggled {
            await assertThrows(try await client.request(action)) { error in
                guard case .actionNotAllowed? = error as? DessMonitorError else { return XCTFail("\(action): \(error)") }
            }
        }
        // Values that would need escaping are refused too: an encoded "&action=" must not get
        // through, and what is signed must be exactly what is sent.
        let malformed = [
            "queryPlants&page=0%26action%3DctrlDevice",
            "queryPlants&page=0 &pagesize=20",
            "queryPlants&page=0#frag",
            "queryPlants&page=0?x=1",
            "queryPlants&page",
            "queryPlants&=1",
            "queryPlants&&page=0",
            "queryPlants&page=0&",
            "queryDeviceLastData&pn=W000/../x",
            "queryDeviceLastData&pn=设备",
        ]
        for action in malformed {
            await assertThrows(try await client.request(action)) { error in
                XCTAssertEqual(error as? DessMonitorError, .invalidRequest(action: String(action.prefix { $0 != "&" })), action)
            }
        }
        XCTAssertEqual(cloud.urls, [], "nothing was sent for any of them")
    }

    func testTheSevenQueriesStillPass() throws {
        for action in [
            "webQueryDeviceEs",
            "queryDevices&page=0&pagesize=50&i18n=en_US",
            "queryDeviceLastData&pn=W0000000000000&devcode=2452&devaddr=1&sn=00000000000000&i18n=en_US",
            "queryDeviceWarning&pn=W0000000000000&devcode=2452&devaddr=1&sn=00000000000000&i18n=en_US&page=0&pagesize=50",
            "queryPlants&page=0&pagesize=20&i18n=en_US",
            "webQueryCollectorsEs&page=0&pagesize=50",
            "queryDeviceDataOneDay&pn=W0000000000000&devcode=2452&devaddr=1&sn=00000000000000&date=2026-10-13&i18n=en_US",
        ] {
            XCTAssertNoThrow(try DessReadOnly.check(action), action)
        }
        // Every request the Node vectors hold is one the gate lets through, unchanged.
        for vector in SigningVectors.flow where vector.action != "authSource" {
            let action = try XCTUnwrap(vector.url.range(of: "&action=").map { String(vector.url[$0.upperBound...]) })
            XCTAssertNoThrow(try DessReadOnly.check(action), action)
        }
    }

    func testARefusedNameIsCleanedBeforeItIsShown() {
        XCTAssertEqual(DessReadOnly.printable("ctrl Device\n<script>"), "ctrlDevicescript")
        XCTAssertEqual(DessReadOnly.printable(""), "(unnamed)")
        XCTAssertEqual(DessReadOnly.printable(String(repeating: "a", count: 100)).count, 40)
    }

    func testTheServiceSendsOnlyAllowListedActions() async throws {
        let cloud = FakeCloud.withFixtures(config: TestAccount.config)
        let service = InverterService(config: TestAccount.config, sessionStore: .memoryOnly, transport: cloud,
                                      now: TestClock().reader)
        _ = try await service.fetchSnapshot()
        _ = try await service.fetchToday()
        cloud.fail("webQueryDeviceEs", code: 1, desc: "ERR_FAIL")   // exercise the fallback list as well
        let again = InverterService(config: TestAccount.config, sessionStore: .memoryOnly, transport: cloud,
                                    now: TestClock().reader)
        _ = try await again.fetchSnapshot()

        let sent = Set(cloud.calls.map(\.action))
        XCTAssertEqual(sent.subtracting(["authSource"]), DessReadOnly.actions, "all seven, and nothing else")
    }

    // MARK: Sources

    func testNoControlActionAppearsInTheShippedSources() throws {
        // Tests/InverterCoreTests/ReadOnlyGuardTests.swift -> package root
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        // Every target, not only InverterCore: the app and its views must not grow a write path either.
        let forbidden = ["ctrlDevice", "queryDeviceCtrlField", "queryDeviceCtrlValue", "ctrlField", "ctrlValue", "action=ctrl"]
        var scanned = 0
        var core = 0
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil),
                                   "no Sources folder at \(sources.path)")
        for case let file as URL in walker where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            scanned += 1
            if file.path.contains("/Sources/InverterCore/") { core += 1 }
            for word in forbidden {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(word), "\(file.lastPathComponent) mentions \(word)")
            }
        }
        // A guard that finds nothing to read has not guarded anything, so that is a failure, not a skip.
        XCTAssertGreaterThanOrEqual(core, 7, "expected the InverterCore sources under \(sources.path)")
        XCTAssertGreaterThan(scanned, core, "expected the other targets' sources as well")
    }

    func testOnlyTheClientBuildsRequestURLs() throws {
        // The token is put into a URL in exactly one file. If another file starts doing it, the
        // read-only gate in DessMonitorClient.send no longer covers every request.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var builders: [String] = []
        for case let file as URL in walker where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("requestURLString(") || text.contains("&token=") { builders.append(file.lastPathComponent) }
        }
        XCTAssertEqual(builders, ["DessMonitorClient.swift"])
    }
}
