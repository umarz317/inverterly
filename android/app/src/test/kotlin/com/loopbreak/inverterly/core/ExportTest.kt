package com.loopbreak.inverterly.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.ZoneOffset

class ExportTest {
    private fun gridTie(pv: Double, load: Double, chargeA: Double = 0.0, type: String? = "Grid Tie") =
        EnergySnapshot(pvPowerW = pv, loadPowerW = load, batteryVoltage = 50.0, batteryChargeA = chargeA, gridVoltage = 230.0, machineType = type)

    @Test fun surplusBeyondLoadAndChargingIsExported() {
        // 3000 W of sun, 1000 W load, battery full: 2000 W spare, less 5% of 3000 W for losses.
        assertEquals(1850.0, gridTie(3000.0, 1000.0).exportPowerW, 1e-6)
        // The battery charging at 20 A (1000 W) takes its share first.
        assertEquals(850.0, gridTie(3000.0, 1000.0, chargeA = 20.0).exportPowerW, 1e-6)
    }

    @Test fun nothingIsExportedFromAConversionLossOrSmallSurplus() {
        // Panels barely above the load: the gap is the inverter's own loss.
        assertEquals(0.0, gridTie(1000.0, 960.0).exportPowerW, 0.0)
        assertEquals(0.0, gridTie(0.0, 300.0).exportPowerW, 0.0)
        assertEquals(0.0, gridTie(500.0, 1200.0).exportPowerW, 0.0)
    }

    @Test fun onlyAGridTieModelCanExport() {
        assertEquals(0.0, gridTie(3000.0, 1000.0, type = "Off Grid Tie").exportPowerW, 0.0)
        assertEquals(0.0, gridTie(3000.0, 1000.0, type = null).exportPowerW, 0.0)
        assertTrue(gridTie(3000.0, 1000.0, type = "grid tie").exportPowerW > 0)
    }

    @Test fun noExportWithoutTheGrid() {
        assertEquals(0.0, gridTie(3000.0, 1000.0).copy(gridVoltage = 0.0).exportPowerW, 0.0)
    }

    @Test fun exportAddsUpOverADay() {
        val zone = ZoneOffset.ofHours(5)
        val dat = Dat.parse("""{"title":[{"title":"Timestamp"},{"title":"PV1 Input Power"},{"title":"AC output active power"},{"title":"Grid voltage"},
            {"title":"Battery voltage"},{"title":"Machine type"}],
            "row":[{"field":["2026-10-13 12:00:00","3000","1000","230","50","Grid Tie"]},{"field":["2026-10-13 12:05:00","3000","1000","230","50","Grid Tie"]}]}""")
        val totals = SnapshotParser.dayTotals(dat, "2026-10-13", zone, complete = true, now = Instant.parse("2026-10-14T00:00:00Z"))!!
        // 1850 W for two 5-minute steps.
        assertEquals(1.85 * 10 / 60, totals.exportKWh, 1e-9)
        assertEquals(0.5, totals.solarKWh, 1e-9)
    }
}
