import XCTest
@testable import InverterCore

final class DayTotalsTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!

    /// A day with the columns the totals need, one report per `(time, pv1, load, grid volts)`.
    private func day(_ reports: [(String, Double, Double, Double)]) throws -> JSONValue {
        let titles = ["Timestamp", "PV1 Input Power", "PV2 Input Power", "AC output active power",
                      "Battery Voltage", "Battery Charging Current", "Battery Discharging Current", "Grid voltage"]
        let title = titles.map { #"{"title":"\#($0)"}"# }.joined(separator: ",")
        let rows = reports.map { time, pv, load, grid in
            #"{"field":["\#(time)","\#(pv)","0","\#(load)","54","0","0","\#(grid)"]}"#
        }.joined(separator: ",")
        return try Fixtures.json(#"{"title":[\#(title)],"row":[\#(rows)]}"#)
    }

    func testSolarAndLoadAreAddedUpOverTime() throws {
        // 4 kW of solar and a 2 kW load for 15 minutes (three reports, five minutes each).
        let dat = try day([("2026-10-13 12:00:00", 4000, 2000, 230), ("2026-10-13 12:05:00", 4000, 2000, 230),
                           ("2026-10-13 12:10:00", 4000, 2000, 230)])
        let totals = try XCTUnwrap(SnapshotParser.dayTotals(dat, day: "2026-10-13", timeZone: utc, complete: true))
        XCTAssertEqual(totals.solarKWh, 1.0, accuracy: 0.001)
        XCTAssertEqual(totals.loadKWh, 0.5, accuracy: 0.001)
        XCTAssertEqual(totals.gridKWh, 0, accuracy: 0.001, "solar covered the load")
        XCTAssertTrue(totals.complete)
    }

    func testGridIsWhatSolarAndBatteryDidNotCover() throws {
        // No solar, 1 kW load, grid present: all of it came from the grid.
        let dat = try day([("2026-10-13 20:00:00", 0, 1000, 230), ("2026-10-13 20:05:00", 0, 1000, 230),
                           ("2026-10-13 20:10:00", 0, 1000, 230)])
        let totals = try XCTUnwrap(SnapshotParser.dayTotals(dat, day: "2026-10-13", timeZone: utc, complete: true))
        XCTAssertEqual(totals.gridKWh, 0.25, accuracy: 0.001)
        XCTAssertEqual(totals.solarKWh, 0)
    }

    func testNoGridMeansNoGridEnergy() throws {
        let dat = try day([("2026-10-13 20:00:00", 0, 1000, 0), ("2026-10-13 20:05:00", 0, 1000, 0)])
        let totals = try XCTUnwrap(SnapshotParser.dayTotals(dat, day: "2026-10-13", timeZone: utc, complete: true))
        XCTAssertEqual(totals.gridKWh, 0)
    }

    func testAGapInTheReportsIsNotFilledWithTheLastValue() throws {
        // One report, then nothing for an hour: it counts for ten minutes, not sixty.
        let dat = try day([("2026-10-13 12:00:00", 6000, 0, 230), ("2026-10-13 13:00:00", 0, 0, 230)])
        let totals = try XCTUnwrap(SnapshotParser.dayTotals(dat, day: "2026-10-13", timeZone: utc, complete: true))
        XCTAssertEqual(totals.solarKWh, 1.0, accuracy: 0.001)
    }

    func testTheLastReportOfADayStillGoingCountsOnlyUntilNow() throws {
        let dat = try day([("2026-10-13 12:00:00", 6000, 0, 230)])
        let now = SnapshotParser.parseTimestamp("2026-10-13 12:01:00", in: utc)!
        let totals = try XCTUnwrap(SnapshotParser.dayTotals(dat, day: "2026-10-13", timeZone: utc, complete: false, now: now))
        XCTAssertEqual(totals.solarKWh, 0.1, accuracy: 0.001)
        XCTAssertFalse(totals.complete)
    }

    func testADayWithNoReportsHasNoTotals() throws {
        XCTAssertNil(try SnapshotParser.dayTotals(.null, day: "2026-10-13", timeZone: utc, complete: true))
    }

    func testMonthsAreGroupedNewestFirst() {
        let days = [DayTotals(day: "2026-09-30", solarKWh: 5, gridKWh: 6, loadKWh: 10, complete: true),
                    DayTotals(day: "2026-10-01", solarKWh: 1, gridKWh: 2, loadKWh: 3, complete: true),
                    DayTotals(day: "2026-10-02", solarKWh: 2, gridKWh: 3, loadKWh: 4, complete: true)]
        let months = MonthTotals.monthly(days)
        XCTAssertEqual(months.map(\.month), ["2026-10", "2026-09"])
        XCTAssertEqual(months[0].days, 2)
        XCTAssertEqual(months[0].solarKWh, 3)
        XCTAssertEqual(months[0].gridKWh, 5)
        XCTAssertEqual(months[0].loadKWh, 7)
    }
}
