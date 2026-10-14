package com.loopbreak.inverterly

import com.loopbreak.inverterly.core.DayCurve
import com.loopbreak.inverterly.core.DayCurvePoint
import com.loopbreak.inverterly.core.DayTotals
import com.loopbreak.inverterly.core.DeviceInfo
import com.loopbreak.inverterly.core.EnergySnapshot
import com.loopbreak.inverterly.core.SnapshotProviding
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/** Made-up readings for a sunny afternoon, for working on the layout without an account (debug builds only). */
class DemoProvider(private val slow: Boolean = false) : SnapshotProviding {
    override suspend fun fetchSnapshot(force: Boolean): EnergySnapshot {
        // `--ez slow true` holds the reading back, to look at the loading screen.
        if (slow) kotlinx.coroutines.delay(20_000)
        return reading()
    }

    private fun reading() = EnergySnapshot(
        deviceTime = Instant.now().minusSeconds(90),
        pvPowerW = 3420.0, pvVoltage = 312.0,
        loadPowerW = 1180.0, loadApparentVA = 1290.0, loadPercent = 20.0,
        outputVoltage = 230.0, outputHz = 50.0,
        batteryPercent = 78.0, batteryVoltage = 53.4, batteryChargeA = 38.0,
        gridVoltage = 236.0, gridHz = 50.0, ratedPowerW = 6000.0,
        todayKWh = 14.2, machineType = "Hybrid 6 kW", collectorOnline = true,
    )

    override suspend fun fetchToday(): DayCurve {
        val zone = ZoneId.systemDefault()
        val start = LocalDate.now(zone).atStartOfDay(zone).toInstant()
        // At least to late afternoon, so the chart has a day's shape whatever the clock says.
        val upTo = max((Instant.now().epochSecond - start.epochSecond).toDouble(), 17.5 * 3600)
        val points = generateSequence(0.0) { it + 300 }.takeWhile { it <= upTo }.map { t ->
            val hour = t / 3600
            val sun = max(0.0, sin((hour - 6) / 13 * Math.PI)) * 4200
            val load = 600 + 500 * max(0.0, sin((hour - 6) / 4)) + if (hour > 18) 900 else 0
            val battery = if (hour < 8) 62 - hour * 3 else min(100.0, 38 + (hour - 8) * 8)
            DayCurvePoint(start.plusSeconds(t.toLong()), sun, load,
                if (sun < load && (hour < 6 || hour > 21)) load - sun else 0.0, battery)
        }.toList()
        return DayCurve(LocalDate.now(zone).toString(), start, points)
    }

    override suspend fun fetchDayTotals(day: String): DayTotals {
        val seed = (day.hashCode() % 1000) / 1000.0
        val isToday = day == LocalDate.now().toString()
        return DayTotals(day, 14 + 8 * abs(seed), 2 + 4 * abs(seed - 0.5), 18 + 3 * abs(seed), !isToday)
    }

    override suspend fun listDevices() = listOf(DeviceInfo("A", "Roof inverter", true), DeviceInfo("B", "Garage inverter"))
    override suspend fun selectDevice(id: String) {}
    override suspend fun reset() {}
}
