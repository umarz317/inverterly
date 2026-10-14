import XCTest
import InverterCore
@testable import InverterUI

/// What the menu bar shows for each choice. Solar gives way to the load when the panels make nothing.
final class MenuBarMetricTests: XCTestCase {
    /// A reading with the panels at `solar` watts. The grid supplies whatever the panels and a 0 A battery leave of `load`.
    private func reading(solar: Double, load: Double = 1180, gridVolts: Double = 230) -> EnergySnapshot {
        EnergySnapshot(pvPowerW: solar, loadPowerW: load, gridVoltage: gridVolts)
    }

    private func text(_ segments: [(symbol: String, text: String)]) -> [String] { segments.map { "\($0.symbol) \($0.text)" } }

    func testSolarShowsThePanelsWhileTheyMakePower() {
        XCTAssertEqual(text(MenuBarMetric.solar.segments(for: reading(solar: 3420))), ["sun.max 3.42 kW"])
    }

    func testSolarShowsTheLoadOnceThePanelsMakeNothing() {
        XCTAssertEqual(text(MenuBarMetric.solar.segments(for: reading(solar: 0))), ["house 1.18 kW"])
        // A few stray watts at dusk count as nothing, as they do for the sun and moon in the panel.
        XCTAssertEqual(text(MenuBarMetric.solar.segments(for: reading(solar: 20))), ["house 1.18 kW"])
        XCTAssertEqual(text(MenuBarMetric.solar.segments(for: reading(solar: 21))), ["sun.max 21 W"])
    }

    func testSolarAndGridShowsBothWhileBothAreWorking() {
        // 500 W of sun against a 1.18 kW load: the grid supplies the other 680 W.
        XCTAssertEqual(text(MenuBarMetric.solarAndGrid.segments(for: reading(solar: 500))), ["sun.max 500 W", "powerplug 680 W"])
    }

    func testSolarAndGridShowsTheLoadInPlaceOfAGridThatIsNotSupplying() {
        // The panels cover the load, so the grid gives nothing: the load takes its place beside the sun.
        XCTAssertEqual(text(MenuBarMetric.solarAndGrid.segments(for: reading(solar: 3420))), ["sun.max 3.42 kW", "house 1.18 kW"])
        // A grid outage is the same: nothing to show from it.
        XCTAssertEqual(text(MenuBarMetric.solarAndGrid.segments(for: reading(solar: 3420, gridVolts: 0))), ["sun.max 3.42 kW", "house 1.18 kW"])
    }

    func testSolarAndGridShowsTheLoadInPlaceOfNoSolar() {
        XCTAssertEqual(text(MenuBarMetric.solarAndGrid.segments(for: reading(solar: 0, load: 900))), ["house 900 W", "powerplug 900 W"])
    }

    func testSolarAndGridShowsTheLoadOnceWhenNeitherIsWorking() {
        // Night with the grid down: the house runs on the battery.
        XCTAssertEqual(text(MenuBarMetric.solarAndGrid.segments(for: reading(solar: 0, load: 900, gridVolts: 0))), ["house 900 W"])
    }

    func testTheOtherChoicesDoNotChangeWithTheSun() {
        XCTAssertEqual(text(MenuBarMetric.load.segments(for: reading(solar: 0))), ["house 1.18 kW"])
        XCTAssertEqual(text(MenuBarMetric.load.segments(for: reading(solar: 3420))), ["house 1.18 kW"])
        XCTAssertTrue(MenuBarMetric.none.segments(for: reading(solar: 0)).isEmpty)
    }
}
