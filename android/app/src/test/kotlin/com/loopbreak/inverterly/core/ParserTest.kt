package com.loopbreak.inverterly.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.ZoneOffset

class ParserTest {
    private val pakistan = ZoneOffset.ofHours(5)
    private val fetchedAt = Instant.parse("2026-10-13T12:25:00Z")

    private fun snapshot() = SnapshotParser.snapshot(
        Dat.parse(Fixtures.lastData), device = SnapshotParser.pickDevice(Dat.parse(Fixtures.devicesEs)),
        timeZone = pakistan, fetchedAt = fetchedAt,
    )

    @Test fun liveReadingFromTheCapturedPayload() {
        val s = snapshot()
        assertEquals(19.0, s.pvPowerW, 0.0)
        assertEquals(119.8, s.pvVoltage!!, 0.0)
        assertEquals(1154.0, s.loadPowerW, 0.0)
        assertEquals(1495.0, s.loadApparentVA!!, 0.0)
        assertEquals(24.0, s.loadPercent!!, 0.0)
        assertEquals(230.0, s.outputVoltage!!, 0.0)
        assertEquals(49.8, s.outputHz!!, 0.0)
        assertEquals(86.0, s.batteryPercent!!, 0.0)
        assertEquals(52.7, s.batteryVoltage!!, 0.0)
        assertEquals(0.0, s.batteryChargeA, 0.0)
        assertEquals(21.0, s.batteryDischargeA, 0.0)
        assertEquals(233.3, s.gridVoltage!!, 0.0)
        assertEquals(6000.0, s.ratedPowerW!!, 0.0)
        assertEquals("Off Grid Tie", s.machineType)
        assertEquals(22.985, s.todayKWh!!, 1e-9)
        assertEquals(9984.879, s.totalKWh!!, 1e-9)
        // The logger's stamp is read in the plant's zone: 17:22:30 at UTC+5 is 12:22:30 UTC.
        assertEquals(Instant.parse("2026-10-13T12:22:30Z"), s.deviceTime)

        // What the model derives from it: on battery, grid present but idle.
        assertEquals(InverterMode.Battery, s.mode)
        assertEquals(-21 * 52.7, s.batteryPowerW, 0.001)
        assertEquals(0.0, s.gridPowerW, 0.0)
        assertTrue(s.gridPresent)
    }

    @Test fun nameplateRowsAreNotTakenForLiveValues() {
        val s = snapshot()
        // "AC output rating active power" = 6000 W sits 22 rows above "AC output active power" = 1154 W.
        assertNotEquals(6000.0, s.loadPowerW, 0.0)
        assertNotEquals(6000.0, s.loadApparentVA!!, 0.0)
        assertEquals(52.7, s.batteryVoltage!!, 0.0)
    }

    @Test fun chargingCurrentIgnoresTheDischargingRow() {
        val rows = Dat.parse("""[{"title":"Battery Discharging Current","unit":"A","val":"9"},{"title":"Battery Charging Current","unit":"A","val":"4"},
            {"title":"Battery Voltage","unit":"V","val":"50"},{"title":"AC output active power","unit":"W","val":"500"}]""")
        val s = SnapshotParser.snapshot(rows, timeZone = pakistan)
        assertEquals(4.0, s.batteryChargeA, 0.0)
        assertEquals(9.0, s.batteryDischargeA, 0.0)
    }

    @Test fun anEmptyPayloadIsNoReadings() {
        try {
            SnapshotParser.snapshot(Dat.parse("[]"))
            throw AssertionError("expected NoReadings")
        } catch (e: InverterDataError.NoReadings) { }
    }

    @Test fun looseNumbersKeepDigitsOnly() {
        assertEquals(990.0, Dat.parse("\"990M\"").looseNumber!!, 0.0)
        assertEquals(52.7, Dat.parse("\"52.7 V\"").looseNumber!!, 0.0)
        assertNull(Dat.parse("\"\"").looseNumber)
        assertNull(Dat.parse("true").looseNumber)
    }

    @Test fun deviceRefReadsLooseTypes() {
        val device = SnapshotParser.pickDevice(Dat.parse("""{"device":[{"pn":"P","sn":"S","devCode":"2452","devAddr":1}]}"""))!!
        assertEquals(2452, device.devcode)
        assertTrue(device.isQueryable)
        assertEquals("pn=P&devcode=2452&devaddr=1&sn=S", device.query)
    }

    @Test fun timestampsAreStrict() {
        assertEquals(Instant.parse("2026-10-13T12:22:30Z"), SnapshotParser.parseTimestamp("2026-10-13 17:22:30", pakistan))
        assertEquals(Instant.parse("2026-10-13T12:22:30Z"), SnapshotParser.parseTimestamp("2026-10-13T17:22:30", pakistan))
        assertNull(SnapshotParser.parseTimestamp("2026-13-13 17:22:30", pakistan))
        assertNull(SnapshotParser.parseTimestamp("nonsense", pakistan))
        assertNull(SnapshotParser.parseTimestamp("2026-10-13 25:00:00", pakistan))
    }

    @Test fun dayCurveAndTotals() {
        val dat = Dat.parse("""{"title":[{"title":"Timestamp"},{"title":"PV1 Input Power"},{"title":"AC output active power"}],
            "row":[{"field":["2026-10-13 10:00:00","3000","1000"]},{"field":["2026-10-13 10:05:00","3000","1000"]},{"field":["2026-10-13 10:10:00","0","1000"]}]}""")
        val curve = SnapshotParser.dayCurve(dat, "2026-10-13", pakistan, fetchedAt)
        assertEquals(3, curve.points.size)
        assertEquals(Instant.parse("2026-10-12T19:00:00Z"), curve.dayStart)
        // 3 kW for two 5-minute steps = 0.5 kWh; the last report counts for five minutes (finished day) at 0 W.
        val totals = SnapshotParser.dayTotals(dat, "2026-10-13", pakistan, complete = true, now = fetchedAt)!!
        assertEquals(0.5, totals.solarKWh, 1e-9)
        assertEquals(1000.0 * 15 / 60 / 1000, totals.loadKWh, 1e-9)
        assertTrue(totals.complete)
    }

    @Test fun missingTimeColumnIsReported() {
        val dat = Dat.parse("""{"title":[{"title":"PV1 Input Power"}],"row":[{"field":["1"]}]}""")
        try {
            SnapshotParser.dayCurve(dat, "2026-10-13", pakistan)
            throw AssertionError("expected MissingColumn")
        } catch (e: InverterDataError.MissingColumn) { }
    }

    @Test fun gridIsEstimatedFromTheBalance() {
        val s = EnergySnapshot(pvPowerW = 500.0, loadPowerW = 2000.0, batteryVoltage = 50.0, batteryChargeA = 10.0, gridVoltage = 230.0)
        assertEquals(2000.0 + 500.0 - 500.0, s.gridPowerW, 1e-9)
        assertEquals(InverterMode.Grid, s.mode)
        assertEquals(0.0, s.copy(gridVoltage = 0.0).gridPowerW, 0.0)
    }

    @Test fun formatting() {
        assertEquals("35 W", PowerFormat.watts(35.0))
        assertEquals("1.14 kW", PowerFormat.watts(1140.0))
        assertEquals("12.4 kW", PowerFormat.watts(12400.0))
        assertEquals("14.2", PowerFormat.kWhNumber(14.2))
        assertEquals("120", PowerFormat.kWhNumber(120.4))
        assertEquals("6 kW", PowerFormat.kilowatts(6000.0))
        assertEquals("3.5 kW", PowerFormat.kilowatts(3500.0))
    }
}
