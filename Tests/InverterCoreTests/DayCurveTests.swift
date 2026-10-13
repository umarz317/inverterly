import XCTest
@testable import InverterCore

final class DayCurveTests: XCTestCase {
    private let pakistan = TimeZone(secondsFromGMT: 5 * 3600)!
    private let fetchedAt = ISO8601DateFormatter().date(from: "2026-10-13T12:25:00Z")!

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    func testCurveFromTheTrimmedCapture() throws {
        let curve = try SnapshotParser.dayCurve(Fixtures.json(Fixtures.dayCurve), day: "2026-10-13", timeZone: pakistan, fetchedAt: fetchedAt)
        XCTAssertEqual(curve.day, "2026-10-13")
        XCTAssertEqual(curve.dayStart, date("2026-10-12T19:00:00Z"), "midnight in Pakistan")
        XCTAssertEqual(curve.dayEnd, date("2026-10-13T19:00:00Z"))
        XCTAssertEqual(curve.fetchedAt, fetchedAt)
        XCTAssertEqual(curve.points.count, 9)
        XCTAssertFalse(curve.isEmpty)

        // time, PV, load, battery: the nine reports kept in the fixture.
        let expected: [(String, Double, Double, Double)] = [
            ("2026-10-12T19:02:31Z", 0, 13, 44),       // 00:02:31 local
            ("2026-10-12T19:07:23Z", 0, 11, 43),
            ("2026-10-13T01:09:15Z", 24, 15, 40),      // 06:09:15, first light
            ("2026-10-13T03:11:45Z", 1548, 14, 46),
            ("2026-10-13T05:16:11Z", 3796, 895, 64),
            ("2026-10-13T07:25:03Z", 4080, 2778, 88),  // 12:25:03, the peak
            ("2026-10-13T09:27:21Z", 2280, 2423, 96),
            ("2026-10-13T12:17:34Z", 35, 1139, 86),    // 17:17:34, the reading quoted in the brief
            ("2026-10-13T12:22:30Z", 19, 1154, 86),
        ]
        for (point, want) in zip(curve.points, expected) {
            XCTAssertEqual(point.time, date(want.0))
            XCTAssertEqual(point.pvW, want.1, want.0)
            XCTAssertEqual(point.loadW, want.2, want.0)
            XCTAssertEqual(point.batteryPercent, want.3, want.0)
        }
        XCTAssertEqual(curve.peakPvW, 4080)
        XCTAssertEqual(curve.peakLoadW, 2778)
        XCTAssertEqual(curve.latest?.loadW, 1154)
        XCTAssertEqual(curve.fraction(of: date("2026-10-13T07:00:00Z")), 0.5, accuracy: 1e-9, "noon is the middle of the axis")
    }

    func testLoadColumnIsTheLiveOneNotTheNameplate() throws {
        // Column 12 is "AC output rating active power" (6000 on every row); column 34 is the live load.
        let curve = try SnapshotParser.dayCurve(Fixtures.json(Fixtures.dayCurve), day: "2026-10-13", timeZone: pakistan)
        XCTAssertFalse(curve.points.contains { $0.loadW == 6000 })
        XCTAssertFalse(curve.points.contains { $0.batteryPercent == 48 }, "not \"Battery Rating Voltage\" either")
    }

    func testRowsAreSortedAndDeduplicated() throws {
        let dat = """
        {"title":[{"title":"Timestamp"},{"title":"PV1 Input Power","unit":"W"},{"title":"PV2 Input Power","unit":"W"},
                  {"title":" AC output active power ","unit":"W"},{"title":"Battery Capacity","unit":"%"}],
         "row":[
           {"realtime":true,"field":["2026-10-13 12:00:00","300","50","700","80"]},
           {"realtime":true,"field":["2026-10-13 08:00:00",100,0,"400","60"]},
           {"realtime":true,"field":["2026-10-13 12:00:00","310","50","710","81"]},
           {"realtime":true,"field":["not a time","1","1","1","1"]},
           {"realtime":true,"field":["2026-10-13 10:00:00","200"]},
           {"realtime":true}
         ]}
        """
        let curve = try SnapshotParser.dayCurve(Fixtures.json(dat), day: "2026-10-13", timeZone: pakistan)
        XCTAssertEqual(curve.points.map(\.time), [date("2026-10-13T03:00:00Z"), date("2026-10-13T05:00:00Z"), date("2026-10-13T07:00:00Z")])
        XCTAssertEqual(curve.points.map(\.pvW), [100, 200, 360], "PV1 + PV2; the later of two identical timestamps wins")
        XCTAssertEqual(curve.points.map(\.loadW), [400, 0, 710], "a short row reads as 0 load")
        XCTAssertEqual(curve.points.map(\.batteryPercent), [60, nil, 81])
    }

    func testNothingStoredYetIsAnEmptyCurve() throws {
        for payload in ["null", "{}", #"{"title":[],"row":[]}"#] {
            let curve = try SnapshotParser.dayCurve(Fixtures.json(payload), day: "2026-10-14", timeZone: pakistan, fetchedAt: fetchedAt)
            XCTAssertTrue(curve.isEmpty, payload)
            XCTAssertEqual(curve.day, "2026-10-14")
            XCTAssertEqual(curve.dayStart, date("2026-10-13T19:00:00Z"))
            XCTAssertEqual(curve.peakPvW, 0)
            XCTAssertNil(curve.latest)
        }
    }

    func testRowsWithoutATimestampColumnAreAnError() {
        let dat = #"{"title":[{"title":"PV1 Input Power"}],"row":[{"field":["12"]}]}"#
        XCTAssertThrowsError(try SnapshotParser.dayCurve(Fixtures.json(dat), day: "2026-10-13", timeZone: pakistan)) { error in
            XCTAssertEqual(error as? InverterDataError, .missingColumn("Timestamp"))
        }
    }
}
