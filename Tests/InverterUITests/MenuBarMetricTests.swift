import XCTest
import InverterCore
@testable import InverterUI

/// What the menu bar shows for each choice. Dynamic puts the load in place of a solar or grid figure with nothing to say.
final class MenuBarMetricTests: XCTestCase {
    /// A reading with the panels at `solar` watts. The grid supplies whatever the panels and a 0 A battery leave of `load`.
    private func reading(solar: Double, load: Double = 1180, gridVolts: Double = 230) -> EnergySnapshot {
        EnergySnapshot(pvPowerW: solar, loadPowerW: load, gridVoltage: gridVolts)
    }

    private func text(_ segments: [(symbol: String, text: String)]) -> [String] { segments.map { "\($0.symbol) \($0.text)" } }

    func testSolarIsAlwaysThePanels() {
        XCTAssertEqual(text(MenuBarMetric.solar.segments(for: reading(solar: 3420))), ["sun.max 3.42 kW"])
        XCTAssertEqual(text(MenuBarMetric.solar.segments(for: reading(solar: 0))), ["moon 0 W"])
    }

    func testDynamicShowsBothWhileBothAreWorking() {
        // 500 W of sun against a 1.18 kW load: the grid supplies the other 680 W.
        XCTAssertEqual(text(MenuBarMetric.dynamic.segments(for: reading(solar: 500))), ["sun.max 500 W", "powerplug 680 W"])
    }

    func testDynamicShowsTheLoadInPlaceOfAGridThatIsNotSupplying() {
        // The panels cover the load, so the grid gives nothing: the load takes its place beside the sun.
        XCTAssertEqual(text(MenuBarMetric.dynamic.segments(for: reading(solar: 3420))), ["sun.max 3.42 kW", "house 1.18 kW"])
        // A grid outage is the same: nothing to show from it.
        XCTAssertEqual(text(MenuBarMetric.dynamic.segments(for: reading(solar: 3420, gridVolts: 0))), ["sun.max 3.42 kW", "house 1.18 kW"])
    }

    func testDynamicShowsTheLoadInPlaceOfNoSolar() {
        XCTAssertEqual(text(MenuBarMetric.dynamic.segments(for: reading(solar: 0, load: 900))), ["house 900 W", "powerplug 900 W"])
    }

    func testDynamicShowsTheLoadOnceWhenNeitherIsWorking() {
        // Night with the grid down: the house runs on the battery.
        XCTAssertEqual(text(MenuBarMetric.dynamic.segments(for: reading(solar: 0, load: 900, gridVolts: 0))), ["house 900 W"])
    }

    func testASavedSolarAndGridChoiceBecomesDynamic() {
        XCTAssertEqual(MenuBarMetric(rawValue: "solarAndGrid"), .dynamic)
        XCTAssertEqual(MenuBarMetric.dynamic.title, "Dynamic")
    }

    func testTheOtherChoicesDoNotChangeWithTheSun() {
        XCTAssertEqual(text(MenuBarMetric.load.segments(for: reading(solar: 0))), ["house 1.18 kW"])
        XCTAssertEqual(text(MenuBarMetric.load.segments(for: reading(solar: 3420))), ["house 1.18 kW"])
        XCTAssertTrue(MenuBarMetric.none.segments(for: reading(solar: 0)).isEmpty)
    }
}
