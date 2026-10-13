import XCTest
import InverterCore
@testable import InverterUI

/// Two inverters; each reading's load is 100 W for the first and 200 W for the second.
private actor TwoInverters: SnapshotProviding {
    private(set) var selected = "A"
    func fetchSnapshot(force: Bool) async throws -> EnergySnapshot { EnergySnapshot(loadPowerW: selected == "A" ? 100 : 200) }
    func fetchToday() async throws -> DayCurve { DayCurve(day: "", dayStart: Date()) }
    func listDevices() async throws -> [DeviceInfo] {
        [DeviceInfo(id: "A", name: "Upstairs", isSelected: selected == "A"), DeviceInfo(id: "B", name: "Downstairs", isSelected: selected == "B")]
    }
    func selectDevice(_ id: String) async { selected = id }
    func fetchDayTotals(day: String) async throws -> DayTotals? { nil }
    func reset() async {}
}

@MainActor
final class DeviceSwitchTests: XCTestCase {
    func testSwitchingShowsTheOtherInverterAndIsRemembered() async throws {
        let suite = "InverterUITests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let provider = TwoInverters()
        let store = AppStore(provider: provider, defaults: defaults)

        await store.refresh(force: true)
        for _ in 0..<50 where store.devices.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.devices.map(\.name), ["Upstairs", "Downstairs"])
        XCTAssertEqual(store.selectedDeviceName, "Upstairs")
        XCTAssertEqual(store.snapshot?.loadPowerW, 100)

        await store.selectDevice("B")
        XCTAssertEqual(store.selectedDeviceName, "Downstairs")
        XCTAssertEqual(store.snapshot?.loadPowerW, 200)
        XCTAssertEqual(defaults.string(forKey: "inverterSN"), "B")
        defaults.removePersistentDomain(forName: suite)
    }
}
