import XCTest
@testable import InverterCore

final class ParserTests: XCTestCase {
    private let pakistan = TimeZone(secondsFromGMT: 5 * 3600)!
    private let fetchedAt = ISO8601DateFormatter().date(from: "2026-10-13T12:25:00Z")!

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func fixtureSnapshot() throws -> EnergySnapshot {
        try SnapshotParser.snapshot(
            lastData: Fixtures.json(Fixtures.lastData),
            warnings: Fixtures.json(Fixtures.warnings),
            plant: SnapshotParser.plant(in: Fixtures.json(Fixtures.plants)),
            collectors: Fixtures.json(Fixtures.collectors),
            device: SnapshotParser.pickDevice(from: Fixtures.json(Fixtures.devicesEs)),
            fetchedAt: fetchedAt)
    }

    // MARK: The captured reading

    func testLiveReadingFromTheCapturedPayload() throws {
        let s = try fixtureSnapshot()
        XCTAssertEqual(s.fetchedAt, fetchedAt)
        XCTAssertEqual(s.pvPowerW, 19)
        XCTAssertEqual(s.pvVoltage, 119.8)
        XCTAssertEqual(s.loadPowerW, 1154)
        XCTAssertEqual(s.loadApparentVA, 1495)
        XCTAssertEqual(s.loadPercent, 24)
        XCTAssertEqual(s.outputVoltage, 230.0)
        XCTAssertEqual(s.outputHz, 49.8)
        XCTAssertEqual(s.batteryPercent, 86)
        XCTAssertEqual(s.batteryVoltage, 52.7)
        XCTAssertEqual(s.batteryChargeA, 0)
        XCTAssertEqual(s.batteryDischargeA, 21)
        XCTAssertEqual(s.gridVoltage, 233.3)
        XCTAssertEqual(s.gridHz, 49.8)
        XCTAssertEqual(s.ratedPowerW, 6000)
        XCTAssertEqual(s.machineType, "Off Grid Tie")
        XCTAssertEqual(s.plantName, "PLANT")
        XCTAssertEqual(s.collectorOnline, true)
        XCTAssertNil(s.activeWarning, "all three captured warnings are cleared")

        // What the model derives from it: on battery, grid present but idle.
        XCTAssertEqual(s.mode, .battery)
        XCTAssertEqual(s.batteryPowerW, -21 * 52.7, accuracy: 0.001)
        XCTAssertEqual(s.gridPowerW, 0)
        XCTAssertTrue(s.gridPresent)
    }

    // MARK: The rating-row trap

    func testNameplateRowsInTheCaptureAreNotTakenForLiveValues() throws {
        let s = try fixtureSnapshot()
        // "AC output rating active power" = 6000 W sits 22 rows above "AC output active power" = 1154 W.
        XCTAssertNotEqual(s.loadPowerW, 6000)
        XCTAssertNotEqual(s.loadApparentVA, 6000)
        // "Battery Rating Voltage" = 48.0, then recharge 47.2, under 47.2, bulk 56.1, float 56.1.
        XCTAssertEqual(s.batteryVoltage, 52.7)
        // The nameplate is still available where it is wanted.
        XCTAssertEqual(s.ratedPowerW, 6000)
    }

    func testNameplateAndSecondOutputRowsAreSkippedWhateverTheOrder() throws {
        // Every look-alike comes first and has a value that differs from the live one.
        let rows = """
        [
          {"title":"AC output rating active power","unit":"W","val":"6000"},
          {"title":"AC output rating apparent power","unit":"VA","val":"6000"},
          {"title":"AC Output Rating Voltage","unit":"V","val":"220.0"},
          {"title":"AC rated frequency","unit":"Hz","val":"60.0"},
          {"title":"Battery Rating Voltage","unit":"V","val":"48.0"},
          {"title":"Grid Rating Current","unit":"A","val":"26.0"},
          {"title":"Second AC output voltage","unit":"V","val":"111.0"},
          {"title":"Second AC output frequency","unit":"Hz","val":"11.0"},
          {"title":"Battery recharge voltage","unit":"V","val":"47.2"},
          {"title":"Battery bulk voltage","unit":"V","val":"56.1"},
          {"title":"PV2 Input voltage","unit":"V","val":"88.0"},
          {"title":"AC output voltage","unit":"V","val":"229.5"},
          {"title":"AC Output Frequency","unit":"Hz","val":"50.1"},
          {"title":"AC output active power","unit":"W","val":"812"},
          {"title":"AC output apparent power","unit":"VA","val":"900"},
          {"title":"Battery Voltage","unit":"V","val":"51.3"},
          {"title":"Battery Discharging Current","unit":"A","val":"3"},
          {"title":"Battery Charging Current","unit":"A","val":"7"},
          {"title":"PV1 Input Power","unit":"W","val":"1500"},
          {"title":"PV2 Input Power","unit":"W","val":"250"},
          {"title":"PV1 Input voltage","unit":"V","val":"240.5"},
          {"title":"Grid voltage","unit":"V","val":"231.0"}
        ]
        """
        let s = try SnapshotParser.snapshot(lastData: Fixtures.json(rows), timeZone: pakistan)
        XCTAssertEqual(s.loadPowerW, 812)
        XCTAssertEqual(s.loadApparentVA, 900)
        XCTAssertEqual(s.outputVoltage, 229.5)
        XCTAssertEqual(s.outputHz, 50.1)
        XCTAssertEqual(s.batteryVoltage, 51.3)
        XCTAssertEqual(s.batteryChargeA, 7, "\"Discharging Current\" contains \"charging current\"; it must not win")
        XCTAssertEqual(s.batteryDischargeA, 3)
        XCTAssertEqual(s.pvPowerW, 1750, "PV1 + PV2")
        XCTAssertEqual(s.pvVoltage, 240.5, "PV1 voltage, not PV2 voltage and not a PV power row")
        XCTAssertEqual(s.gridVoltage, 231.0)
        XCTAssertEqual(s.ratedPowerW, 6000)
    }

    func testChargeSettingRowsAreNotTakenForTheLiveBatteryCurrent() throws {
        // Other models in this family list their charge settings among the readings, before the
        // live rows. Matching on "charging current" alone (as the Node client does) would report
        // the battery as charging at 60 A for ever.
        let rows = """
        [
          {"title":"Max charging current","unit":"A","val":"60"},
          {"title":"Max AC charging current","unit":"A","val":"30"},
          {"title":"Max discharging current","unit":"A","val":"120"},
          {"title":"Battery Voltage","unit":"V","val":"51.3"},
          {"title":"Battery Discharging Current","unit":"A","val":"3"},
          {"title":"Battery Charging Current","unit":"A","val":"7"}
        ]
        """
        let s = try SnapshotParser.snapshot(lastData: Fixtures.json(rows), timeZone: pakistan)
        XCTAssertEqual(s.batteryChargeA, 7)
        XCTAssertEqual(s.batteryDischargeA, 3)

        // The battery row exists but is empty: that is "no reading", not a cue to take the setting.
        let empty = """
        [
          {"title":"Max charging current","unit":"A","val":"60"},
          {"title":"Battery Voltage","unit":"V","val":"51.3"},
          {"title":"Battery Charging Current","unit":"A","val":""}
        ]
        """
        XCTAssertEqual(try SnapshotParser.snapshot(lastData: Fixtures.json(empty), timeZone: pakistan).batteryChargeA, 0)

        // A model that names the rows differently still reads, by the Node client's looser titles.
        let loose = """
        [
          {"title":"Battery Voltage","unit":"V","val":"51.3"},
          {"title":"Discharge current","unit":"A","val":"4"},
          {"title":"Charging current","unit":"A","val":"9"},
          {"title":"电池放电电流","unit":"A","val":"1"}
        ]
        """
        let l = try SnapshotParser.snapshot(lastData: Fixtures.json(loose), timeZone: pakistan)
        XCTAssertEqual(l.batteryChargeA, 9)
        XCTAssertEqual(l.batteryDischargeA, 4)
    }

    // MARK: Energy units

    func testWattHoursBecomeKilowattHours() throws {
        let s = try fixtureSnapshot()
        XCTAssertEqual(try XCTUnwrap(s.todayKWh), 22.985, accuracy: 1e-9)      // "22985" Wh
        XCTAssertEqual(try XCTUnwrap(s.monthKWh), 322.639, accuracy: 1e-9)     // "322639" Wh
        XCTAssertEqual(try XCTUnwrap(s.yearKWh), 5408.657, accuracy: 1e-9)     // "5408657" Wh
        XCTAssertEqual(try XCTUnwrap(s.totalKWh), 9984.879, accuracy: 1e-9)    // "9984.879" kWh, left alone
    }

    func testEnergyWithoutAUnitUsesTheNodeClientsGuess() throws {
        let rows = """
        [
          {"title":"Battery Voltage","val":"50"},
          {"title":"Today generation","val":"3500"},
          {"title":"Month generation","val":"140.5"},
          {"title":"Year generation","unit":"MWh","val":"5.4"},
          {"title":"Total generation","unit":" kWh ","val":9984.5}
        ]
        """
        let s = try SnapshotParser.snapshot(lastData: Fixtures.json(rows), timeZone: pakistan)
        XCTAssertEqual(s.todayKWh, 3.5, "no unit and above 2000: taken as Wh")
        XCTAssertEqual(s.monthKWh, 140.5, "no unit and small: taken as kWh")
        XCTAssertEqual(try XCTUnwrap(s.yearKWh), 5400, accuracy: 1e-9)
        XCTAssertEqual(s.totalKWh, 9984.5)
    }

    // MARK: Timestamp

    func testDeviceTimeIsTheLoggerTimestampInThePlantsZone() throws {
        let s = try fixtureSnapshot()
        // "Timestamp" = 2026-10-13 17:22:30 and the plant is UTC+5.
        XCTAssertEqual(s.deviceTime, date("2026-10-13T12:22:30Z"))
        // "Date Time" = 2026-10-14 04:50:55 is the inverter's own (wrong) clock and must not be used.
        XCTAssertNotEqual(s.deviceTime, SnapshotParser.parseTimestamp("2026-10-14 04:50:55", in: pakistan))
        XCTAssertFalse(s.isStale(now: fetchedAt))
        XCTAssertTrue(s.isStale(now: fetchedAt.addingTimeInterval(20 * 60)))
    }

    func testTimeZoneFallsBackFromPlantToDeviceToCollector() throws {
        let last = Fixtures.json(Fixtures.lastData)
        let viaDevice = try SnapshotParser.snapshot(
            lastData: last, device: SnapshotParser.pickDevice(from: Fixtures.json(Fixtures.devices)))
        XCTAssertEqual(viaDevice.deviceTime, date("2026-10-13T12:22:30Z"), "queryDevices reports timezone 18000")

        let viaCollector = try SnapshotParser.snapshot(lastData: last, collectors: Fixtures.json(Fixtures.collectors))
        XCTAssertEqual(viaCollector.deviceTime, date("2026-10-13T12:22:30Z"), "the collector reports timeZone 18000")

        let explicit = try SnapshotParser.snapshot(lastData: last, plant: SnapshotParser.plant(in: Fixtures.json(Fixtures.plants)),
                                                   timeZone: TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(explicit.deviceTime, date("2026-10-13T17:22:30Z"), "an explicit zone wins")
    }

    func testMissingOrBrokenTimestampLeavesDeviceTimeNil() throws {
        let noStamp = #"[{"title":"Date Time","val":"2026-10-14 04:50:55"},{"title":"Battery Voltage","val":"52.7"}]"#
        XCTAssertNil(try SnapshotParser.snapshot(lastData: Fixtures.json(noStamp), timeZone: pakistan).deviceTime)
        let broken = #"[{"title":"Timestamp","val":"yesterday"},{"title":"Battery Voltage","val":"52.7"}]"#
        XCTAssertNil(try SnapshotParser.snapshot(lastData: Fixtures.json(broken), timeZone: pakistan).deviceTime)
    }

    func testParseTimestamp() {
        XCTAssertEqual(SnapshotParser.parseTimestamp("2026-10-13 17:22:30", in: pakistan), date("2026-10-13T12:22:30Z"))
        XCTAssertEqual(SnapshotParser.parseTimestamp(" 2026-10-13T00:00:00 ", in: pakistan), date("2026-10-12T19:00:00Z"))
        XCTAssertEqual(SnapshotParser.parseTimestamp("2026-10-13 17:22", in: pakistan), date("2026-10-13T12:22:00Z"))
        XCTAssertEqual(SnapshotParser.parseTimestamp("2026-10-13 17:22:30.750", in: pakistan), date("2026-10-13T12:22:30Z"))
        for bad in ["", "2026-10-13", "17:22:30", "2026-13-01 00:00:00", "2026-10-13 24:00:00", "2026-10-13 10:61:00", "a-b-c d:e:f"] {
            XCTAssertNil(SnapshotParser.parseTimestamp(bad, in: pakistan), bad)
        }
    }

    func testDayString() {
        XCTAssertEqual(SnapshotParser.dayString(for: date("2026-10-13T12:25:00Z"), in: pakistan), "2026-10-13")
        XCTAssertEqual(SnapshotParser.dayString(for: date("2026-10-13T19:00:00Z"), in: pakistan), "2026-10-14", "midnight in Pakistan")
        XCTAssertEqual(SnapshotParser.dayString(for: date("2026-10-13T18:59:59Z"), in: pakistan), "2026-10-13")
    }

    // MARK: Loose types

    func testNumbersMayArriveAsStringsNumbersOrDecorated() throws {
        let rows = """
        [
          {"title":"Grid voltage","val":233.3},
          {"title":"Grid frequency","val":"49.8 Hz"},
          {"title":"AC output active power","val":" 1154 "},
          {"title":"Battery Voltage","val":"52.7V"},
          {"title":"Battery Capacity","value":86},
          {"title":"Battery Charging Current","val":""},
          {"title":"Battery Discharging Current","val":null},
          {"title":"PV1 Input Power","val":"n/a"}
        ]
        """
        let s = try SnapshotParser.snapshot(lastData: Fixtures.json(rows), timeZone: pakistan)
        XCTAssertEqual(s.gridVoltage, 233.3)
        XCTAssertEqual(s.gridHz, 49.8)
        XCTAssertEqual(s.loadPowerW, 1154)
        XCTAssertEqual(s.batteryVoltage, 52.7)
        XCTAssertEqual(s.batteryPercent, 86, "`value` is accepted where `val` is absent")
        XCTAssertEqual(s.batteryChargeA, 0)
        XCTAssertEqual(s.batteryDischargeA, 0)
        XCTAssertEqual(s.pvPowerW, 0)
        XCTAssertNil(s.outputVoltage, "a reading that is not there stays nil instead of becoming 0")
    }

    func testOlderParsShapedPayload() throws {
        let dat = """
        {"pars": {
          "gd_": [{"par":"Grid voltage","val":"230.1","unit":"V"}],
          "bt_": [{"par":"Battery Voltage","val":"50.4","unit":"V"},{"par":"Battery Capacity","val":"71","unit":"%"}],
          "bc_": [{"par":"AC output active power","val":"640","unit":"W"}]
        }}
        """
        let s = try SnapshotParser.snapshot(lastData: Fixtures.json(dat), timeZone: pakistan)
        XCTAssertEqual(s.gridVoltage, 230.1)
        XCTAssertEqual(s.batteryVoltage, 50.4)
        XCTAssertEqual(s.batteryPercent, 71)
        XCTAssertEqual(s.loadPowerW, 640)
    }

    func testNothingRecognisableIsAnErrorNotAZeroReading() {
        for payload in ["[]", "{}", "null", #"[{"title":"id","val":"abc"},{"title":"Machine type","val":"Off Grid Tie"}]"#] {
            XCTAssertThrowsError(try SnapshotParser.snapshot(lastData: Fixtures.json(payload), timeZone: pakistan), payload) { error in
                XCTAssertEqual(error as? InverterDataError, .noReadings)
            }
        }
    }

    // MARK: Warnings

    func testActiveWarningIsTheNewestOneNotCleared() throws {
        XCTAssertNil(SnapshotParser.activeWarning(in: Fixtures.json(Fixtures.warnings)))
        XCTAssertNil(SnapshotParser.activeWarning(in: nil))
        XCTAssertNil(SnapshotParser.activeWarning(in: Fixtures.json(#"{"total":0,"warning":[]}"#)))

        let mixed = """
        {"warning":[
          {"status":false,"title":"Line fail","desc":"Line fail"},
          {"status":"false","title":"Old as text"},
          {"status":0,"title":"Old as number"},
          {"status":true,"title":"","desc":"Battery low","code":"0x00000010"},
          {"status":true,"title":"Over temperature"}
        ]}
        """
        XCTAssertEqual(SnapshotParser.activeWarning(in: Fixtures.json(mixed)), "Battery low",
                       "first one whose status is not false; desc stands in for an empty title")

        let s = try SnapshotParser.snapshot(lastData: Fixtures.json(Fixtures.lastData), warnings: Fixtures.json(mixed), timeZone: pakistan)
        XCTAssertEqual(s.activeWarning, "Battery low")
    }

    // MARK: Plant, collector, device

    func testPlant() {
        let plant = SnapshotParser.plant(in: Fixtures.json(Fixtures.plants))
        XCTAssertEqual(plant?.name, "PLANT")
        XCTAssertEqual(plant?.id, 1)
        XCTAssertEqual(plant?.timeZone?.secondsFromGMT(), 18000)

        let two = Fixtures.json(#"{"plant":[{"pid":7,"name":"Shop"},{"pid":"9","name":"Home","address":{"timezone":"18000"}}]}"#)
        XCTAssertEqual(SnapshotParser.plant(in: two)?.name, "Shop", "first when nothing is preferred")
        XCTAssertEqual(SnapshotParser.plant(in: two, preferID: 9)?.name, "Home", "the device's own plant when known")
        XCTAssertEqual(SnapshotParser.plant(in: two, preferID: 9)?.timeZone?.secondsFromGMT(), 18000)
        XCTAssertEqual(SnapshotParser.plant(in: two, preferID: 1234)?.name, "Shop")
        XCTAssertNil(SnapshotParser.plant(in: Fixtures.json(#"{"plant":[]}"#)))
        XCTAssertNil(SnapshotParser.plant(in: nil))
    }

    func testCollectorStatus() {
        XCTAssertEqual(SnapshotParser.collectorOnline(in: Fixtures.json(Fixtures.collectors), pn: "W0000000000000"), true)
        // The vendor's device-status table: 0 online, 1 offline, 2 fault, 3 standby, 4 warning,
        // 5 error, 6 protocol error. Only 1 means the logger is not connected.
        let two = Fixtures.json(#"{"collector":[{"pn":"A","status":1},{"pn":"B","status":"0"},{"pn":"C","status":4},{"pn":"D","status":9},{"pn":"E"},{"pn":"F","status":2},{"pn":"G","status":6}]}"#)
        XCTAssertEqual(SnapshotParser.collectorOnline(in: two, pn: "A"), false)
        XCTAssertEqual(SnapshotParser.collectorOnline(in: two, pn: "B"), true)
        XCTAssertEqual(SnapshotParser.collectorOnline(in: two, pn: "C"), true, "a warning is reported by a logger that is connected")
        XCTAssertEqual(SnapshotParser.collectorOnline(in: two, pn: "F"), true)
        XCTAssertEqual(SnapshotParser.collectorOnline(in: two, pn: "G"), true)
        XCTAssertNil(SnapshotParser.collectorOnline(in: two, pn: "D"), "a code outside the vendor's table is not guessed")
        XCTAssertNil(SnapshotParser.collectorOnline(in: two, pn: "E"), "nor is a missing one")
        XCTAssertEqual(SnapshotParser.collectorOnline(in: two, pn: "unknown"), false, "falls back to the first")
        XCTAssertNil(SnapshotParser.collectorOnline(in: nil))
        XCTAssertNil(SnapshotParser.collectorOnline(in: Fixtures.json("{}")))
    }

    func testPickDeviceFromBothListings() throws {
        let fromEs = try XCTUnwrap(SnapshotParser.pickDevice(from: Fixtures.json(Fixtures.devicesEs)))
        XCTAssertEqual(fromEs.pn, "W0000000000000")
        XCTAssertEqual(fromEs.sn, "00000000000000")
        XCTAssertEqual(fromEs.devcode, 2452)
        XCTAssertEqual(fromEs.devaddr, 1)
        XCTAssertEqual(fromEs.alias, "Inverter")
        XCTAssertEqual(fromEs.plantID, 1)
        XCTAssertNil(fromEs.timeZoneOffset)
        XCTAssertTrue(fromEs.isQueryable)
        XCTAssertEqual(fromEs.query, "pn=W0000000000000&devcode=2452&devaddr=1&sn=00000000000000")

        let fromFallback = try XCTUnwrap(SnapshotParser.pickDevice(from: Fixtures.json(Fixtures.devices)))
        XCTAssertEqual(fromFallback.devcode, 2452)
        XCTAssertEqual(fromFallback.timeZoneOffset, 18000)
    }

    func testPickDevicePrefersTheConfiguredOneAndToleratesLooseTypes() throws {
        let list = Fixtures.json("""
        {"device":[
          {"pn":"P1","sn":"S1","devcode":"100","devaddr":"3"},
          {"pn":"P2","sn":"S2","devCode":200,"devAddr":5,"deviceAlias":"Roof"},
          {"pn":"P3","sn":"S3"}
        ]}
        """)
        let first = try XCTUnwrap(SnapshotParser.pickDevice(from: list))
        XCTAssertEqual([first.pn, first.sn], ["P1", "S1"])
        XCTAssertEqual(first.devcode, 100, "a device code sent as a string still reads")
        XCTAssertEqual(first.devaddr, 3)

        let bySN = try XCTUnwrap(SnapshotParser.pickDevice(from: list, preferPN: "nope", preferSN: "S2"))
        XCTAssertEqual(bySN.devcode, 200)
        XCTAssertEqual(bySN.devaddr, 5)
        XCTAssertEqual(bySN.alias, "Roof")

        let byPN = try XCTUnwrap(SnapshotParser.pickDevice(from: list, preferPN: "P3"))
        XCTAssertEqual(byPN.devcode, 0)
        XCTAssertEqual(byPN.devaddr, 1, "same defaults as the JS: devcode 0, devaddr 1")
        XCTAssertFalse(byPN.isQueryable, "device code 0 means the stick is not bound yet")

        XCTAssertEqual(SnapshotParser.pickDevice(from: list, preferPN: "nope", preferSN: "nope")?.pn, "P1")
        XCTAssertNil(SnapshotParser.pickDevice(from: Fixtures.json(#"{"device":[]}"#)))
        XCTAssertNil(SnapshotParser.pickDevice(from: .null))
        XCTAssertEqual(SnapshotParser.pickDevice(from: Fixtures.json(#"[{"pn":"A","sn":"B","devcode":1}]"#))?.pn, "A")
    }
}

final class JSONValueTests: XCTestCase {
    func testCoercions() throws {
        let value = try JSONValue.parse(#"{"n":2452,"s":"2452","f":"233.3","t":true,"z":0,"e":"","nil":null,"big":1791894032123,"neg":"-5","txt":"abc","b":"false"}"#)
        XCTAssertEqual(value["n"]?.intValue, 2452)
        XCTAssertEqual(value["s"]?.intValue, 2452)
        XCTAssertEqual(value["n"]?.stringValue, "2452", "no trailing .0")
        XCTAssertEqual(value["f"]?.doubleValue, 233.3)
        XCTAssertEqual(value["big"]?.stringValue, "1791894032123")
        XCTAssertEqual(value["neg"]?.intValue, -5)
        XCTAssertNil(value["txt"]?.doubleValue)
        XCTAssertNil(value["e"]?.doubleValue)
        XCTAssertNil(value["e"]?.nonEmptyString)
        XCTAssertEqual(value["e"]?.stringValue, "")
        XCTAssertNil(value["nil"], "null reads as absent")
        XCTAssertNil(value["missing"])
        XCTAssertEqual(value["t"], .bool(true), "true stays a boolean, it is not the number 1")
        XCTAssertEqual(value["t"]?.boolValue, true)
        XCTAssertEqual(value["z"]?.boolValue, false)
        XCTAssertEqual(value["b"]?.boolValue, false)
        XCTAssertNil(value["txt"]?.boolValue)
        XCTAssertNil(value["t"]?.doubleValue)
        XCTAssertEqual(value[any: "missing", "s"]?.stringValue, "2452")
    }

    func testLooseNumber() {
        XCTAssertEqual(JSONValue.string("990M").looseNumber, 990)
        XCTAssertEqual(JSONValue.string("52.7 V").looseNumber, 52.7)
        XCTAssertEqual(JSONValue.string("-3").looseNumber, -3)
        XCTAssertEqual(JSONValue.number(6000).looseNumber, 6000)
        XCTAssertNil(JSONValue.string("").looseNumber)
        XCTAssertNil(JSONValue.string("Off Grid Tie").looseNumber)
        XCTAssertNil(JSONValue.string("1.2.3").looseNumber)
        XCTAssertNil(JSONValue.null.looseNumber)
        XCTAssertNil(JSONValue.bool(true).looseNumber)
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try JSONValue.parse("<html>502 Bad Gateway</html>"))
    }
}
