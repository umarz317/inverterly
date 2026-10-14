package com.loopbreak.inverterly.core

import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset
import java.util.Locale
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min

/**
 * What is carrying the load right now. The vendor feed has no mode row for this inverter, so this
 * is inferred from the power balance (see [EnergySnapshot.mode]).
 */
enum class InverterMode(val label: String) {
    Solar("On solar"),
    Battery("On battery"),
    Grid("On grid"),
    Standby("Standby"),
    Unknown("Unknown"),
}

/**
 * One reading of the inverter, already converted to plain numbers. Powers are watts, energies are
 * kWh. Read-only: nothing here can change a setting.
 */
data class EnergySnapshot(
    val fetchedAt: Instant = Instant.now(),
    /** When the Wi-Fi logger last reported to the vendor cloud (about every 5 minutes). */
    val deviceTime: Instant? = null,

    val pvPowerW: Double = 0.0,
    val pvVoltage: Double? = null,

    val loadPowerW: Double = 0.0,
    val loadApparentVA: Double? = null,
    val loadPercent: Double? = null,
    val outputVoltage: Double? = null,
    val outputHz: Double? = null,

    val batteryPercent: Double? = null,
    val batteryVoltage: Double? = null,
    val batteryChargeA: Double = 0.0,
    val batteryDischargeA: Double = 0.0,

    val gridVoltage: Double? = null,
    val gridHz: Double? = null,

    val ratedPowerW: Double? = null,

    val todayKWh: Double? = null,
    val monthKWh: Double? = null,
    val yearKWh: Double? = null,
    val totalKWh: Double? = null,

    /** Title of a warning that is active right now, null when there is none. */
    val activeWarning: String? = null,
    val plantName: String? = null,
    val machineType: String? = null,
    val collectorOnline: Boolean? = null,
) {
    /** Battery power in watts. Positive while charging, negative while discharging. */
    val batteryPowerW: Double get() = (batteryChargeA - batteryDischargeA) * (batteryVoltage ?: 0.0)

    val gridPresent: Boolean get() = (gridVoltage ?: 0.0) > 90

    /**
     * Grid power is not reported, so it is whatever the load and battery charging need beyond what
     * PV and battery discharge supply. Battery current is reported in whole amps (about 50 W per
     * step at 48 V), so small positive balances are treated as rounding.
     *
     * While the battery is discharging the inverter is in battery mode and takes nothing from the
     * grid, even with grid voltage present, so the balance is not consulted at all then.
     */
    val gridPowerW: Double
        get() {
            if (!gridPresent || batteryDischargeA > 0.4) return 0.0
            val balance = loadPowerW + batteryPowerW - pvPowerW
            val floor = max(60.0, loadPowerW * 0.05)
            return if (balance > floor) balance else 0.0
        }

    val mode: InverterMode
        get() = when {
            batteryDischargeA > 0.4 -> InverterMode.Battery
            gridPowerW > 0 -> InverterMode.Grid
            pvPowerW > 20 -> InverterMode.Solar
            loadPowerW < 20 -> InverterMode.Standby
            else -> InverterMode.Unknown
        }

    val flows: EnergyFlows
        get() = EnergyFlows(max(0.0, pvPowerW), gridPowerW, batteryPowerW, max(0.0, loadPowerW))

    /** True when the logger's last report is older than [seconds]. */
    fun isStale(seconds: Long = 15 * 60, now: Instant = Instant.now()): Boolean {
        val time = deviceTime ?: return false
        return Duration.between(time, now).seconds > seconds
    }
}

/** The four power flows the UI animates. [batteryW] is signed: positive charges the battery. */
data class EnergyFlows(
    val solarW: Double = 0.0,
    val gridW: Double = 0.0,
    val batteryW: Double = 0.0,
    val loadW: Double = 0.0,
) {
    val batteryChargeW: Double get() = max(0.0, batteryW)
    val batteryDischargeW: Double get() = max(0.0, -batteryW)

    fun mix(other: EnergyFlows, t: Double): EnergyFlows {
        fun lerp(a: Double, b: Double) = a + (b - a) * t
        return EnergyFlows(lerp(solarW, other.solarW), lerp(gridW, other.gridW),
            lerp(batteryW, other.batteryW), lerp(loadW, other.loadW))
    }

    companion object { val Zero = EnergyFlows() }
}

object PowerFormat {
    private fun fmt(pattern: String, value: Double) = String.format(Locale.US, pattern, value)

    /** "35 W", "1.14 kW", "12.4 kW". */
    fun watts(value: Double): String {
        val v = abs(value)
        if (v < 1000) return "${Math.round(v)} W"
        return fmt(if (v < 10_000) "%.2f kW" else "%.1f kW", v / 1000)
    }

    /** Number and unit apart, for big numerals: ("1.14", "kW"). */
    fun split(value: Double): Pair<String, String> {
        val v = abs(value)
        if (v < 1000) return Math.round(v).toString() to "W"
        return fmt(if (v < 10_000) "%.2f" else "%.1f", v / 1000) to "kW"
    }

    fun kWh(value: Double) = kWhNumber(value) + " kWh"

    /** The number alone, for tables headed "kWh": one decimal below 100, none above. */
    fun kWhNumber(value: Double) = fmt(if (value < 100) "%.1f" else "%.0f", value)

    /** "6 kW", "3.5 kW" for a rating. */
    fun kilowatts(watts: Double): String {
        val kw = watts / 1000
        return if (kw == Math.rint(kw)) "${kw.toInt()} kW" else fmt("%.1f kW", kw)
    }
}

/** One logger report (about every 5 minutes) reduced to what a small chart needs. */
data class DayCurvePoint(
    val time: Instant,
    /** PV1 + PV2 input power, watts. */
    val pvW: Double,
    /** AC output active power, watts. */
    val loadW: Double,
    /** Estimated grid draw, watts, worked out like [EnergySnapshot.gridPowerW]. */
    val gridW: Double = 0.0,
    val batteryPercent: Double? = null,
)

/** Today's readings in time order. Empty right after midnight, before the first report of the day. */
data class DayCurve(
    /** The plant's calendar day, "2026-10-13". */
    val day: String,
    /** Midnight at the start of [day] in the plant's time zone; the chart's x axis runs 24 h from here. */
    val dayStart: Instant,
    val points: List<DayCurvePoint> = emptyList(),
    val fetchedAt: Instant = Instant.now(),
) {
    val isEmpty get() = points.isEmpty()
    val dayEnd: Instant get() = dayStart.plusSeconds(24 * 3600)

    data class Totals(val solarKWh: Double, val gridKWh: Double, val loadKWh: Double)

    /**
     * Energy so far today, in kWh, added up the same way as [SnapshotParser.dayTotals]: each reading
     * counts until the next one, at most ten minutes, and the last one until [now], at most five.
     */
    fun totals(now: Instant = Instant.now()): Totals {
        var solar = 0.0; var grid = 0.0; var load = 0.0
        for ((index, point) in points.withIndex()) {
            val seconds = if (index + 1 < points.size) {
                min(secondsBetween(point.time, points[index + 1].time), 600.0)
            } else {
                min(300.0, max(0.0, secondsBetween(point.time, now)))
            }
            val hours = seconds / 3600
            solar += max(0.0, point.pvW) * hours
            grid += point.gridW * hours
            load += max(0.0, point.loadW) * hours
        }
        return Totals(solar / 1000, grid / 1000, load / 1000)
    }

    /** The reading closest to [time], or null without one. */
    fun pointNear(time: Instant?): DayCurvePoint? {
        if (time == null) return null
        return points.minByOrNull { abs(secondsBetween(it.time, time)) }
    }
}

internal fun secondsBetween(a: Instant, b: Instant): Double =
    (b.toEpochMilli() - a.toEpochMilli()) / 1000.0

/** What one day came to, in kWh: solar made, grid drawn and load served. */
data class DayTotals(
    /** The plant's calendar day, "2026-10-13". */
    val day: String,
    val solarKWh: Double,
    val gridKWh: Double,
    val loadKWh: Double,
    /** False for a day that was still going when it was read; those are read again. */
    val complete: Boolean,
)

/** The days of one month added up. */
data class MonthTotals(
    /** "2026-10" */
    val month: String,
    val days: Int,
    val solarKWh: Double,
    val gridKWh: Double,
    val loadKWh: Double,
) {
    companion object {
        /** Groups days by month, newest month first. */
        fun monthly(days: Collection<DayTotals>): List<MonthTotals> {
            val byMonth = LinkedHashMap<String, MonthTotals>()
            for (day in days) {
                val month = day.day.take(7)
                val t = byMonth[month] ?: MonthTotals(month, 0, 0.0, 0.0, 0.0)
                byMonth[month] = t.copy(days = t.days + 1, solarKWh = t.solarKWh + day.solarKWh,
                    gridKWh = t.gridKWh + day.gridKWh, loadKWh = t.loadKWh + day.loadKWh)
            }
            return byMonth.values.sortedByDescending { it.month }
        }
    }
}

/** The inverter the account is bound to, as the cloud addresses it. */
data class DeviceRef(
    /** Wi-Fi stick (collector) PN. */
    val pn: String,
    /** Inverter serial number. */
    val sn: String,
    val devcode: Int,
    val devaddr: Int = 1,
    val alias: String = "",
    val plantID: Int? = null,
    /** Seconds east of UTC, when the device list reports it. */
    val timeZoneOffset: Int? = null,
) {
    /** Something the cloud can actually be asked about. A device with code 0 is not bound yet. */
    val isQueryable: Boolean get() = devcode != 0 && pn.isNotEmpty() && sn.isNotEmpty()

    /** The device part of a query, in the order the Node client sends it. */
    val query: String get() = "pn=$pn&devcode=$devcode&devaddr=$devaddr&sn=$sn"

    val timeZone: ZoneId? get() = timeZoneOffset?.let(::zoneFromOffset)
}

/** One inverter on the account, for a picker. */
data class DeviceInfo(
    /** The inverter's serial number. */
    val id: String,
    /** What to call it: its alias, else its machine type ("Off Grid Tie"), else "Inverter 2". */
    val name: String,
    /** True for the inverter the readings are about. */
    val isSelected: Boolean = false,
)

data class PlantInfo(
    val id: Int? = null,
    val name: String,
    /** The plant's own time zone. The logger's timestamps are in it. */
    val timeZone: ZoneId? = null,
)

internal fun zoneFromOffset(seconds: Int): ZoneId? =
    try { ZoneOffset.ofTotalSeconds(seconds) } catch (_: Exception) { null }

/** Used by the hero: 0…1 intensity for a power, compressed so 100 W is visible and 6 kW is not a blur. */
object HeroMath {
    fun intensity(watts: Double, full: Double = 5000.0): Double {
        if (watts <= 1) return 0.0
        return min(1.0, max(0.12, log10(1 + watts / 40) / log10(1 + full / 40)))
    }

    fun fract(x: Double) = x - floor(x)

    /** Stable pseudo-random 0…1 for an integer seed (no state, same every frame). */
    fun hash(seed: Int): Double = fract(kotlin.math.sin(seed * 12.9898 + 4.1414) * 43758.5453)
}
