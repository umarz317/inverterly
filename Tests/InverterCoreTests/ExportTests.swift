import XCTest
@testable import InverterCore

/// Grid export is an estimate from the power balance, for a "Grid Tie" model only.
final class ExportTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!

    private func gridTie(pv: Double, load: Double, chargeA: Double = 0, type: String? = "Grid Tie") -> EnergySnapshot {
        EnergySnapshot(pvPowerW: pv, loadPowerW: load, batteryVoltage: 50, batteryChargeA: chargeA, gridVoltage: 230, machineType: type)
    }

    func testSurplusBeyondLoadAndChargingIsExported() {
        // 3000 W of sun, 1000 W load, battery full: 2000 W spare, less 5% of 3000 W for losses.
        XCTAssertEqual(gridTie(pv: 3000, load: 1000).exportPowerW, 1850, accuracy: 1e-6)
        // The battery charging at 20 A (1000 W) takes its share first.
        XCTAssertEqual(gridTie(pv: 3000, load: 1000, chargeA: 20).exportPowerW, 850, accuracy: 1e-6)
    }

    func testNothingIsExportedFromAConversionLossOrSmallSurplus() {
        // Panels barely above the load: the gap is the inverter's own loss.
        XCTAssertEqual(gridTie(pv: 1000, load: 960).exportPowerW, 0)
        XCTAssertEqual(gridTie(pv: 0, load: 300).exportPowerW, 0)
        XCTAssertEqual(gridTie(pv: 500, load: 1200).exportPowerW, 0)
    }

    func testOnlyAGridTieModelCanExport() {
        XCTAssertEqual(gridTie(pv: 3000, load: 1000, type: "Off Grid Tie").exportPowerW, 0)
        XCTAssertEqual(gridTie(pv: 3000, load: 1000, type: nil).exportPowerW, 0)
        XCTAssertGreaterThan(gridTie(pv: 3000, load: 1000, type: "grid tie").exportPowerW, 0)
    }

    func testNoExportWithoutTheGrid() {
        var snapshot = gridTie(pv: 3000, load: 1000)
        snapshot.gridVoltage = 0
        XCTAssertEqual(snapshot.exportPowerW, 0)
    }

    func testExportReachesTheFlowsAndEasesWithThem() {
        let flows = gridTie(pv: 3000, load: 1000).flows
        XCTAssertEqual(flows.exportW, 1850, accuracy: 1e-6)
        XCTAssertEqual(EnergyFlows.zero.mix(flows, 0.5).exportW, 925, accuracy: 1e-6)
        XCTAssertNotEqual(flows, EnergyFlows(solarW: flows.solarW, gridW: flows.gridW, batteryW: flows.batteryW, loadW: flows.loadW))
    }

    func testExportAddsUpOverADay() throws {
        let dat = try Fixtures.json(#"""
        {"title":[{"title":"Timestamp"},{"title":"PV1 Input Power"},{"title":"AC output active power"},{"title":"Grid voltage"},
                  {"title":"Battery voltage"},{"title":"Machine type"}],
         "row":[{"field":["2026-10-13 12:00:00","3000","1000","230","50","Grid Tie"]},
                {"field":["2026-10-13 12:05:00","3000","1000","230","50","Grid Tie"]}]}
        """#)
        let totals = try XCTUnwrap(SnapshotParser.dayTotals(dat, day: "2026-10-13", timeZone: utc, complete: true))
        // 1850 W for two five-minute steps.
        XCTAssertEqual(try XCTUnwrap(totals.exportKWh), 1.85 * 10 / 60, accuracy: 1e-9)
        XCTAssertEqual(totals.solarKWh, 0.5, accuracy: 1e-9)
        let curve = try SnapshotParser.dayCurve(dat, day: "2026-10-13", timeZone: utc)
        XCTAssertEqual(curve.points.map(\.exportW), [1850, 1850])
    }

    func testMonthsAddUpExport() {
        let days = [DayTotals(day: "2026-10-12", solarKWh: 10, gridKWh: 1, loadKWh: 8, complete: true, exportKWh: 2),
                    DayTotals(day: "2026-10-13", solarKWh: 12, gridKWh: 0, loadKWh: 9, complete: true, exportKWh: 3.5),
                    // A day saved before export was estimated counts as none rather than breaking the sum.
                    DayTotals(day: "2026-10-14", solarKWh: 5, gridKWh: 0, loadKWh: 4, complete: true, exportKWh: nil)]
        XCTAssertEqual(MonthTotals.monthly(days).first?.exportKWh ?? -1, 5.5, accuracy: 1e-9)
    }

    func testSavedDaysWithoutAnExportFigureAreReadAgain() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = HistoryStore(fileURL: scratch.appendingPathComponent("history.json"))
        // One entry as the app wrote it before export was estimated, and one as it writes it now.
        let old = #"{"day":"2026-10-11","solarKWh":10,"gridKWh":1,"loadKWh":8,"complete":true}"#
        let new = #"{"day":"2026-10-12","solarKWh":10,"gridKWh":1,"loadKWh":8,"complete":true,"exportKWh":2.5}"#
        try Data(#"{"SN1/2026-10-11":\#(old),"SN1/2026-10-12":\#(new)}"#.utf8).write(to: file.fileURL!)

        let kept = file.load()
        XCTAssertEqual(Set(kept.keys), ["SN1/2026-10-12"], "the old day is dropped so it is read from the cloud once more")
        file.save(kept)
        XCTAssertEqual(file.load()["SN1/2026-10-12"]?.exportKWh, 2.5, "a new save keeps the figure")
    }
}
