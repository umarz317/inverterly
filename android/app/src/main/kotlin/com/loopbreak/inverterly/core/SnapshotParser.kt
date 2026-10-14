package com.loopbreak.inverterly.core

import kotlinx.serialization.json.JsonElement
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId

/**
 * Pure functions from decoded API payloads to the app's model. No network, no clock unless passed
 * in, so every rule here is unit-tested.
 *
 * Rows are matched by title the way `mapLastData` in the Node client does it, because the feed has
 * no stable field ids. The trap is that nameplate rows sit next to live ones with nearly the same
 * title ("AC output rating active power" = 6000 W, "AC output active power" = 1154 W), and the
 * second output has its own "Second AC output voltage". Live lookups skip both.
 */
object SnapshotParser {

    // region Rows

    internal data class Row(
        /** Title as the cloud spells it. */
        val title: String,
        /** Lowercased "title name par", the string the needles are matched against. */
        val label: String,
        val value: JsonElement?,
        val unit: String,
    )

    /**
     * `rowsFrom()` in the Node client: the payload is normally a flat array of `{title, val, unit}`,
     * but older endpoints nest it under `pars`, `row`, `field` or `list`.
     */
    internal fun tableRows(dat: JsonElement?): List<Row> {
        dat.array?.let { return it.map(::row) }
        dat["pars"].obj?.let { groups ->
            val out = ArrayList<Row>()
            for (key in groups.keys.sorted()) {
                for (item in groups[key].array ?: emptyList()) {
                    val title = item.firstText("par", "title", "id") ?: ""
                    val name = item.firstText("par", "name") ?: ""
                    out += Row(title, "$title $name ".lowercase(), item["val"], item["unit"].string ?: "")
                }
            }
            return out
        }
        for (key in listOf("row", "field", "list")) dat[key].array?.let { return it.map(::row) }
        return emptyList()
    }

    private fun row(item: JsonElement): Row {
        val title = item["title"].string ?: ""
        val name = item["name"].string ?: ""
        val par = item["par"].string ?: ""
        return Row(title, "$title $name $par".lowercase(), item.any("val", "value"), item["unit"].string ?: "")
    }

    private fun isNameplate(label: String) = "rating" in label || "rated" in label

    /**
     * `findVal()`: the first live row whose title contains any needle. Nameplate rows are never
     * live values, and [skip] removes look-alikes such as the second output.
     */
    internal fun liveValue(rows: List<Row>, needles: List<String>, skip: List<String> = emptyList()): Double? =
        liveRow(rows, needles, skip)?.value?.looseNumber

    /** The row [liveValue] reads, so a caller can tell "no such row" from "row with no number". */
    internal fun liveRow(rows: List<Row>, needles: List<String>, skip: List<String> = emptyList()): Row? {
        for (row in rows) {
            if (isNameplate(row.label)) continue
            if (skip.any { it in row.label }) continue
            if (needles.any { it in row.label }) return row
        }
        return null
    }

    /**
     * A battery current. The exact battery row is preferred, because some models also list a "Max
     * charging current" setting among the readings and it would otherwise win by coming first.
     */
    internal fun batteryCurrent(rows: List<Row>, exact: List<String>, loose: List<String>, skip: List<String>): Double? {
        val settings = listOf("max", "limit", "setting")
        liveRow(rows, exact, skip + settings)?.let { return it.value?.looseNumber }
        return liveValue(rows, loose, skip)
    }

    /** `findRated()`: the first row whose title contains any needle, nameplate rows included. */
    internal fun anyValue(rows: List<Row>, needles: List<String>): Double? {
        for (row in rows) if (needles.any { it in row.label }) return row.value?.looseNumber
        return null
    }

    internal fun text(rows: List<Row>, needles: List<String>): String? {
        for (row in rows) if (needles.any { it in row.label }) return row.value.nonEmptyString
        return null
    }

    /**
     * `energyKwh()`: Wh becomes kWh, kWh stays. With no unit, a figure above 2000 is taken to be Wh,
     * the same guess the Node client makes.
     */
    internal fun energyKWh(rows: List<Row>, needles: List<String>): Double? {
        for (row in rows) {
            if (needles.none { it in row.label }) continue
            val value = row.value?.looseNumber ?: continue
            return when (row.unit.trim().lowercase()) {
                "wh" -> value / 1000
                "kwh" -> value
                "mwh" -> value * 1000
                else -> if (value > 2000) value / 1000 else value
            }
        }
        return null
    }

    // endregion

    // region Snapshot

    /**
     * Builds the reading from `queryDeviceLastData`. The other payloads are optional extras:
     * `queryDeviceWarning` for the active warning, `webQueryCollectorsEs` for the logger status.
     *
     * [timeZone] is the zone the logger's "Timestamp" row is written in. When null it is taken from
     * the plant, then the device, then the collector, and only then from this phone.
     */
    fun snapshot(
        lastData: JsonElement?,
        warnings: JsonElement? = null,
        plant: PlantInfo? = null,
        collectors: JsonElement? = null,
        device: DeviceRef? = null,
        timeZone: ZoneId? = null,
        fetchedAt: Instant = Instant.now(),
    ): EnergySnapshot {
        val rows = tableRows(lastData)

        val gridVoltage = liveValue(rows, listOf("grid voltage", "ac grid", "电网电压", "市电电压"))
        val gridHz = liveValue(rows, listOf("grid frequency", "电网频率", "市电频率"))
        val outputVoltage = liveValue(rows, listOf("ac output voltage", "output voltage", "输出电压"), listOf("second"))
        val outputHz = liveValue(rows, listOf("ac output frequency", "output frequency", "输出频率"), listOf("second"))
        val apparent = liveValue(rows, listOf("apparent", "视在"), listOf("second"))
        val load = liveValue(rows, listOf("active power", "output power", "输出功率", "有功"), listOf("second"))
        val loadPercent = liveValue(rows, listOf("load percent", "负载百分比", "load %"))
        val batteryVoltage = liveValue(rows, listOf("battery voltage", "电池电压"))
        val batteryPercent = liveValue(rows, listOf("battery capacity", "soc", "电池容量"))
        // "Battery Discharging Current" contains "charging current", so the charging lookup has to
        // skip anything with "discharg" in it, as the Node client does.
        val charge = batteryCurrent(rows, listOf("battery charging current", "battery charge current"),
            listOf("charging current", "充电电流"), listOf("discharg"))
        val discharge = batteryCurrent(rows, listOf("battery discharging current", "battery discharge current"),
            listOf("discharge current", "discharging current", "放电电流"), emptyList())
        // The Node client matches PV voltage on a bare "pv1" and PV2 power on a bare "pv2", which
        // would pick the wrong row on a model that lists a PV2 voltage first. Be stricter here.
        val pvVoltage = liveValue(rows, listOf("pv1 input voltage", "pv1 voltage", "pv input voltage", "pv输入电压"))
        val pv1 = liveValue(rows, listOf("pv1 input power", "pv1 power", "光伏功率"), listOf("pv2"))
            ?: liveValue(rows, listOf("pv input power", "pv power"), listOf("pv1", "pv2"))
        val pv2 = liveValue(rows, listOf("pv2 input power", "pv2 power"))

        if (load == null && batteryVoltage == null && pv1 == null && gridVoltage == null) {
            throw InverterDataError.NoReadings
        }

        val logger = collector(collectors, device?.pn)
        val zone = timeZone ?: plant?.timeZone ?: device?.timeZone ?: logger.second ?: ZoneId.systemDefault()
        // "Timestamp" is when the logger last reported. "Date Time" is the inverter's own clock,
        // which on this unit is hours off, so it is deliberately not used.
        val stamp = rows.firstOrNull { it.title.trim().lowercase() == "timestamp" }?.value.string
        val plantName = plant?.name?.trim()

        return EnergySnapshot(
            fetchedAt = fetchedAt,
            deviceTime = stamp?.let { parseTimestamp(it, zone) },
            pvPowerW = (pv1 ?: 0.0) + (pv2 ?: 0.0),
            pvVoltage = pvVoltage,
            loadPowerW = load ?: 0.0,
            loadApparentVA = apparent,
            loadPercent = loadPercent,
            outputVoltage = outputVoltage,
            outputHz = outputHz,
            batteryPercent = batteryPercent,
            batteryVoltage = batteryVoltage,
            batteryChargeA = charge ?: 0.0,
            batteryDischargeA = discharge ?: 0.0,
            gridVoltage = gridVoltage,
            gridHz = gridHz,
            ratedPowerW = anyValue(rows, listOf("ac output rating active", "ac output rated active", "rated active power")),
            todayKWh = energyKWh(rows, listOf("today generation", "today", "daily")),
            monthKWh = energyKWh(rows, listOf("month generation", "month")),
            yearKWh = energyKWh(rows, listOf("year generation", "year")),
            totalKWh = energyKWh(rows, listOf("total generation", "total energy", "lifetime")),
            activeWarning = activeWarning(warnings),
            plantName = plantName?.ifEmpty { null },
            machineType = text(rows, listOf("machine type")),
            collectorOnline = logger.first,
        )
    }

    // endregion

    // region Side payloads

    /**
     * Title of the newest warning that has not cleared. `status == false` means cleared; the cloud
     * lists warnings newest first.
     */
    fun activeWarning(warnings: JsonElement?): String? {
        if (warnings == null) return null
        for (warning in warnings["warning"].array ?: warnings.array ?: emptyList()) {
            if (warning["status"].bool == false) continue
            warning.firstText("title", "desc", "code")?.let { return it }
        }
        return null
    }

    /** The plant from `queryPlants`: the one the device belongs to when that is known, else the first. */
    fun plant(plants: JsonElement?, preferID: Int? = null): PlantInfo? {
        if (plants == null) return null
        val list = plants["plant"].array ?: plants.array ?: emptyList()
        val match = preferID?.let { id -> list.firstOrNull { it["pid"].int == id } }
        val hit = match ?: list.firstOrNull() ?: return null
        val offset = hit["address"]["timezone"].int
        return PlantInfo(hit["pid"].int, hit["name"].string ?: "", offset?.let(::zoneFromOffset))
    }

    /**
     * Logger state from `webQueryCollectorsEs`. Its `status` uses the vendor's device-status table:
     * 0 online and running normally, 1 offline, and 2 fault, 3 standby, 4 warning, 5 error,
     * 6 protocol error, all of which the cloud can only know about a logger that is connected. A
     * code outside the table is left unknown.
     */
    internal fun collector(collectors: JsonElement?, pn: String?): Pair<Boolean?, ZoneId?> {
        if (collectors == null) return null to null
        val list = collectors["collector"].array ?: collectors.array ?: emptyList()
        val match = pn?.let { p -> list.firstOrNull { it["pn"].string == p } }
        val hit = match ?: list.firstOrNull() ?: return null to null
        val online = when (hit["status"].int) {
            1 -> false
            0, 2, 3, 4, 5, 6 -> true
            else -> null
        }
        val zone = hit.any("timeZone", "timezone").int?.let(::zoneFromOffset)
        return online to zone
    }

    fun collectorOnline(collectors: JsonElement?, pn: String? = null): Boolean? = collector(collectors, pn).first

    /** `pickDevice()` in the Node client: the device matching the preferred PN or SN, else the first. */
    fun pickDevice(devices: JsonElement?, preferPN: String? = null, preferSN: String? = null): DeviceRef? {
        val list = deviceEntries(devices)
        val first = list.firstOrNull() ?: return null
        val hit = list.firstOrNull { device ->
            (preferPN != null && device["pn"].string == preferPN) ||
                (preferSN != null && (device["sn"].string == preferSN || device["deviceAlias"].string == preferSN))
        } ?: first
        return deviceRef(hit, preferPN, preferSN)
    }

    /** Every device in a `webQueryDeviceEs` or `queryDevices` answer. */
    fun allDevices(devices: JsonElement?): List<DeviceRef> = deviceEntries(devices).map { deviceRef(it) }

    private fun deviceEntries(devices: JsonElement?): List<JsonElement> =
        devices.array ?: devices["device"].array ?: devices["page"]["device"].array ?: devices["dat"].array ?: emptyList()

    private fun deviceRef(hit: JsonElement, preferPN: String? = null, preferSN: String? = null) = DeviceRef(
        pn = hit["pn"].nonEmptyString ?: preferPN ?: "",
        sn = hit["sn"].nonEmptyString ?: preferSN ?: "",
        devcode = hit.any("devcode", "devCode").int ?: 0,
        devaddr = hit.any("devaddr", "devAddr").int ?: 1,
        alias = hit.firstText("alias", "deviceAlias", "devalias", "name") ?: "",
        plantID = hit["pid"].int,
        timeZoneOffset = hit.any("timezone", "timeZone").int,
    )

    // endregion

    // region Day curve

    /**
     * Builds the chart series from `queryDeviceDataOneDay`, which returns the column titles once
     * (`title`) and then one `field` array per logger report (`row`). Columns are found by title.
     * The endpoint returns the whole day in one answer (295 rows for a full day).
     */
    fun dayCurve(dat: JsonElement?, day: String, timeZone: ZoneId, fetchedAt: Instant = Instant.now()): DayCurve {
        val dayStart = parseTimestamp("$day 00:00:00", timeZone)
            ?: fetchedAt.atZone(timeZone).toLocalDate().atStartOfDay(timeZone).toInstant()
        val empty = DayCurve(day, dayStart, emptyList(), fetchedAt)

        val reports = dat["row"].array ?: emptyList()
        if (reports.isEmpty()) return empty

        val column = dayColumns(dat)
        val timeColumn = column("timestamp") ?: throw InverterDataError.MissingColumn("Timestamp")
        val loadColumn = column("ac output active power")
        val pv1Column = column("pv1 input power")
        val pv2Column = column("pv2 input power")
        val batteryColumn = column("battery capacity")
        val voltageColumn = column("battery voltage")
        val chargeColumn = column("battery charging current")
        val dischargeColumn = column("battery discharging current")
        val gridColumn = column("grid voltage")
        val typeColumn = column("machine type")

        val byTime = HashMap<Instant, DayCurvePoint>()
        for (report in reports) {
            val fields = report["field"].array ?: report.array ?: continue
            fun number(index: Int?): Double? = if (index == null || index !in fields.indices) null else fields[index].looseNumber
            if (timeColumn !in fields.indices) continue
            val stamp = fields[timeColumn].string ?: continue
            val time = parseTimestamp(stamp, timeZone) ?: continue
            val reading = EnergySnapshot(
                pvPowerW = (number(pv1Column) ?: 0.0) + (number(pv2Column) ?: 0.0),
                loadPowerW = number(loadColumn) ?: 0.0,
                batteryVoltage = number(voltageColumn),
                batteryChargeA = number(chargeColumn) ?: 0.0,
                batteryDischargeA = number(dischargeColumn) ?: 0.0,
                gridVoltage = number(gridColumn),
                machineType = typeColumn?.let { fields.getOrNull(it).string },
            )
            byTime[time] = DayCurvePoint(time, reading.pvPowerW, reading.loadPowerW, reading.gridPowerW, number(batteryColumn),
                reading.exportPowerW)
        }
        return empty.copy(points = byTime.values.sortedBy { it.time })
    }

    /** Finds a column of `queryDeviceDataOneDay` by title. */
    private fun dayColumns(dat: JsonElement?): (String) -> Int? {
        val titles = (dat["title"].array ?: emptyList()).map {
            (it["title"].string ?: it.string ?: "").trim().lowercase()
        }
        return { name ->
            titles.indexOf(name).takeIf { it >= 0 }
                ?: titles.indexOfFirst { name in it && !isNameplate(it) && "second" !in it }.takeIf { it >= 0 }
        }
    }

    /**
     * Adds up one day of reports into kWh, the same way as [DayCurve.totals]. The last report counts
     * for five minutes, or until [now] while the day is still going. Null if the day has no reports.
     */
    fun dayTotals(dat: JsonElement?, day: String, timeZone: ZoneId, complete: Boolean, now: Instant = Instant.now()): DayTotals? {
        val curve = dayCurve(dat, day, timeZone, now)
        val last = curve.points.lastOrNull() ?: return null
        val sum = curve.totals(if (complete) last.time.plusSeconds(300) else now)
        return DayTotals(day, sum.solarKWh, sum.gridKWh, sum.loadKWh, complete, sum.exportKWh)
    }

    // endregion

    // region Time

    /** The plant's calendar day containing [date], as the API wants it: "2026-10-13". */
    fun dayString(date: Instant, zone: ZoneId): String = date.atZone(zone).toLocalDate().toString()

    /** Parses the cloud's "2026-10-13 17:22:30" (a "T" separator and fractional seconds are tolerated). */
    fun parseTimestamp(text: String, zone: ZoneId): Instant? {
        val halves = text.trim().split(' ', 'T').filter { it.isNotEmpty() }
        if (halves.size != 2) return null
        val date = halves[0].split('-').map { it.toIntOrNull() }
        val time = halves[1].split(':').map { it.toDoubleOrNull() }
        if (date.size != 3 || (time.size != 2 && time.size != 3)) return null
        val year = date[0] ?: return null
        val month = date[1] ?: return null
        val day = date[2] ?: return null
        val hour = time[0] ?: return null
        val minute = time[1] ?: return null
        val second = if (time.size == 3) (time[2] ?: return null) else 0.0
        if (month !in 1..12 || day !in 1..31 || hour < 0 || hour >= 24 || minute < 0 || minute >= 60 ||
            second < 0 || second >= 61 || hour != Math.rint(hour) || minute != Math.rint(minute)) return null
        return try {
            LocalDateTime.of(year, month, day, hour.toInt(), minute.toInt(), minOf(second.toInt(), 59))
                .atZone(zone).toInstant()
        } catch (_: Exception) {
            null
        }
    }

    // endregion
}
