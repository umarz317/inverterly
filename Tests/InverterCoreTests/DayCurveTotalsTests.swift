import XCTest
@testable import InverterCore

final class DayCurveTotalsTests: XCTestCase {
    func testTotalsCountEachReadingUntilTheNextCappedAtTenMinutes() {
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let curve = DayCurve(day: "2025-10-09", dayStart: start, points: [
            DayCurvePoint(time: start, pvW: 1200, loadW: 600, gridW: 0),
            DayCurvePoint(time: start.addingTimeInterval(300), pvW: 0, loadW: 1200, gridW: 1200),
            // A 30-minute gap: the reading above only counts for ten minutes.
            DayCurvePoint(time: start.addingTimeInterval(2100), pvW: 0, loadW: 600, gridW: 600),
        ])
        let totals = curve.totals(now: start.addingTimeInterval(2100 + 120))
        XCTAssertEqual(totals.solarKWh, 0.1, accuracy: 1e-9)                    // 1200 W for 5 min
        XCTAssertEqual(totals.gridKWh, 0.2 + 0.02, accuracy: 1e-9)              // 1200 W for 10 min + 600 W for 2 min
        XCTAssertEqual(totals.loadKWh, 0.05 + 0.2 + 0.02, accuracy: 1e-9)
    }
}
