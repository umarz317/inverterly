import XCTest
@testable import InverterCore

final class ModelTests: XCTestCase {
    func testBatteryModeFromLiveReading() {
        // Reading taken from the real inverter on 13 Oct 2026: on battery, grid present but idle.
        let s = EnergySnapshot(pvPowerW: 35, loadPowerW: 1139, batteryPercent: 86, batteryVoltage: 52.8,
                               batteryChargeA: 0, batteryDischargeA: 22, gridVoltage: 233.7)
        XCTAssertEqual(s.mode, .battery)
        XCTAssertEqual(s.batteryPowerW, -1161.6, accuracy: 0.01)
        XCTAssertEqual(s.gridPowerW, 0)
    }

    func testOnBatteryNeverShowsAGridFlow() {
        // Live reading of 13 Oct 2026, 18:06:46. The balance comes to +69 W, a little over the
        // rounding floor, purely from the whole-amp battery current. The inverter was on battery.
        let s = EnergySnapshot(pvPowerW: 0, loadPowerW: 1281, batteryPercent: 79, batteryVoltage: 52.7,
                               batteryChargeA: 0, batteryDischargeA: 23, gridVoltage: 235.9)
        XCTAssertEqual(s.mode, .battery)
        XCTAssertTrue(s.gridPresent)
        XCTAssertEqual(s.gridPowerW, 0)
        XCTAssertEqual(s.flows.gridW, 0)
        XCTAssertEqual(s.flows.batteryDischargeW, 23 * 52.7, accuracy: 0.01)
    }

    func testGridCarriesLoadAndCharging() {
        let s = EnergySnapshot(pvPowerW: 0, loadPowerW: 820, batteryVoltage: 50.1, batteryChargeA: 20, gridVoltage: 229)
        XCTAssertEqual(s.mode, .grid)
        XCTAssertEqual(s.gridPowerW, 820 + 20 * 50.1, accuracy: 0.01)
    }

    func testSolarCoversEverything() {
        let s = EnergySnapshot(pvPowerW: 3420, loadPowerW: 1980, batteryVoltage: 54.2, batteryChargeA: 24, gridVoltage: 232)
        XCTAssertEqual(s.mode, .solar)
        XCTAssertEqual(s.gridPowerW, 0)
    }

    func testNoGridMeansNoGridPower() {
        let s = EnergySnapshot(pvPowerW: 0, loadPowerW: 2650, batteryVoltage: 47.9, batteryDischargeA: 20, gridVoltage: 0)
        XCTAssertEqual(s.gridPowerW, 0)
    }

    func testPowerFormat() {
        XCTAssertEqual(PowerFormat.watts(35), "35 W")
        XCTAssertEqual(PowerFormat.watts(1139), "1.14 kW")
        XCTAssertEqual(PowerFormat.watts(-1161.6), "1.16 kW")
        XCTAssertEqual(PowerFormat.watts(12_400), "12.4 kW")
    }
}
