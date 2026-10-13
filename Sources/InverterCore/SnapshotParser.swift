import Foundation

/// The inverter the account is bound to, as the cloud addresses it.
public struct DeviceRef: Sendable, Equatable {
    /// Wi-Fi stick (collector) PN.
    public var pn: String
    /// Inverter serial number.
    public var sn: String
    public var devcode: Int
    public var devaddr: Int
    public var alias: String
    public var plantID: Int?
    /// Seconds east of UTC, when the device list reports it.
    public var timeZoneOffset: Int?

    public init(pn: String, sn: String, devcode: Int, devaddr: Int = 1, alias: String = "",
                plantID: Int? = nil, timeZoneOffset: Int? = nil) {
        self.pn = pn; self.sn = sn; self.devcode = devcode; self.devaddr = devaddr
        self.alias = alias; self.plantID = plantID; self.timeZoneOffset = timeZoneOffset
    }

    /// Something the cloud can actually be asked about. A device with code 0 is not bound yet.
    public var isQueryable: Bool { devcode != 0 && !pn.isEmpty && !sn.isEmpty }

    /// The device part of a query, in the order the Node client sends it.
    var query: String { "pn=\(pn)&devcode=\(devcode)&devaddr=\(devaddr)&sn=\(sn)" }

    var timeZone: TimeZone? { timeZoneOffset.flatMap { TimeZone(secondsFromGMT: $0) } }
}

/// One inverter on the account, for a picker.
public struct DeviceInfo: Sendable, Equatable, Identifiable {
    /// The inverter's serial number.
    public var id: String
    /// What to call it: its alias, else its machine type ("Off Grid Tie"), else "Inverter 2".
    public var name: String
    /// True for the inverter the readings are about.
    public var isSelected: Bool

    public init(id: String, name: String, isSelected: Bool = false) {
        self.id = id; self.name = name; self.isSelected = isSelected
    }
}

public struct PlantInfo: Sendable, Equatable {
    public var id: Int?
    public var name: String
    /// The plant's own time zone. The logger's timestamps are in it.
    public var timeZone: TimeZone?

    public init(id: Int? = nil, name: String, timeZone: TimeZone? = nil) {
        self.id = id; self.name = name; self.timeZone = timeZone
    }
}

public enum InverterDataError: Error, Equatable, Sendable {
    /// The login works but no inverter is bound to the account.
    case noDevice
    /// The cloud answered, but with nothing that reads as a live value.
    case noReadings
    case missingColumn(String)
}

extension InverterDataError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noDevice: return "The account has no inverter bound to it yet."
        case .noReadings: return "The inverter cloud returned no readings."
        case .missingColumn(let name): return "The day history has no \"\(name)\" column."
        }
    }
}

/// Pure functions from decoded API payloads to the app's model. No network, no clock unless
/// passed in, so every rule here is unit-tested against a captured payload.
///
/// Rows are matched by title the way `mapLastData` in the Node client does it, because the feed
/// has no stable field ids. The trap is that nameplate rows sit next to live ones with nearly the
/// same title ("AC output rating active power" = 6000 W, "AC output active power" = 1154 W), and
/// the second output has its own "Second AC output voltage". Live lookups skip both.
public enum SnapshotParser {

    // MARK: Rows

    struct Row: Equatable {
        /// Title as the cloud spells it.
        var title: String
        /// Lowercased "title name par", the string the needles are matched against.
        var label: String
        var value: JSONValue?
        var unit: String
    }

    /// `rowsFrom()` in the Node client: the payload is normally a flat array of
    /// `{title, val, unit}`, but older endpoints nest it under `pars`, `row`, `field` or `list`.
    static func tableRows(from dat: JSONValue) -> [Row] {
        if let array = dat.arrayValue { return array.map(row) }
        if let groups = dat["pars"]?.objectValue {
            var out: [Row] = []
            for key in groups.keys.sorted() {
                for item in groups[key]?.arrayValue ?? [] {
                    let title = item.firstText("par", "title", "id") ?? ""
                    let name = item.firstText("par", "name") ?? ""
                    out.append(Row(title: title, label: "\(title) \(name) ".lowercased(),
                                   value: item["val"], unit: item["unit"]?.stringValue ?? ""))
                }
            }
            return out
        }
        for key in ["row", "field", "list"] {
            if let array = dat[key]?.arrayValue { return array.map(row) }
        }
        return []
    }

    private static func row(_ item: JSONValue) -> Row {
        let title = item["title"]?.stringValue ?? ""
        let name = item["name"]?.stringValue ?? ""
        let par = item["par"]?.stringValue ?? ""
        return Row(title: title, label: "\(title) \(name) \(par)".lowercased(),
                   value: item[any: "val", "value"], unit: item["unit"]?.stringValue ?? "")
    }

    private static func isNameplate(_ label: String) -> Bool {
        label.contains("rating") || label.contains("rated")
    }

    /// `findVal()`: the first live row whose title contains any needle. Nameplate rows are never
    /// live values, and `skip` removes look-alikes such as the second output.
    static func liveValue(_ rows: [Row], _ needles: [String], skip: [String] = []) -> Double? {
        liveRow(rows, needles, skip: skip)?.value?.looseNumber
    }

    /// The row `liveValue` reads, so a caller can tell "no such row" from "row with no number".
    static func liveRow(_ rows: [Row], _ needles: [String], skip: [String] = []) -> Row? {
        for row in rows {
            if isNameplate(row.label) { continue }
            if skip.contains(where: { row.label.contains($0) }) { continue }
            if needles.contains(where: { row.label.contains($0) }) { return row }
        }
        return nil
    }

    /// A battery current. The exact battery row is preferred, because some models also list a
    /// "Max charging current" setting among the readings and it would otherwise win by coming first.
    /// Only when there is no such row do the Node client's looser titles apply.
    static func batteryCurrent(_ rows: [Row], exact: [String], loose: [String], skip: [String]) -> Double? {
        let settings = ["max", "limit", "setting"]
        if let row = liveRow(rows, exact, skip: skip + settings) { return row.value?.looseNumber }
        return liveValue(rows, loose, skip: skip)
    }

    /// `findRated()`: the first row whose title contains any needle, nameplate rows included.
    static func anyValue(_ rows: [Row], _ needles: [String]) -> Double? {
        for row in rows where needles.contains(where: { row.label.contains($0) }) {
            return row.value?.looseNumber
        }
        return nil
    }

    static func text(_ rows: [Row], _ needles: [String]) -> String? {
        for row in rows where needles.contains(where: { row.label.contains($0) }) {
            return row.value?.nonEmptyString
        }
        return nil
    }

    /// `energyKwh()`: Wh becomes kWh, kWh stays. With no unit, a figure above 2000 is taken to be
    /// Wh, the same guess the Node client makes. The result is not rounded.
    static func energyKWh(_ rows: [Row], _ needles: [String]) -> Double? {
        for row in rows where needles.contains(where: { row.label.contains($0) }) {
            guard let value = row.value?.looseNumber else { continue }
            switch row.unit.trimmingCharacters(in: .whitespaces).lowercased() {
            case "wh": return value / 1000
            case "kwh": return value
            case "mwh": return value * 1000
            default: return value > 2000 ? value / 1000 : value
            }
        }
        return nil
    }

    // MARK: Snapshot

    /// Builds the reading from `queryDeviceLastData`. The other payloads are optional extras:
    /// `queryDeviceWarning` for the active warning, `webQueryCollectorsEs` for the logger status.
    ///
    /// `timeZone` is the zone the logger's "Timestamp" row is written in. When nil it is taken from
    /// the plant, then the device, then the collector, and only then from this Mac.
    public static func snapshot(lastData: JSONValue,
                                warnings: JSONValue? = nil,
                                plant: PlantInfo? = nil,
                                collectors: JSONValue? = nil,
                                device: DeviceRef? = nil,
                                timeZone: TimeZone? = nil,
                                fetchedAt: Date = Date()) throws -> EnergySnapshot {
        let rows = tableRows(from: lastData)

        let gridVoltage = liveValue(rows, ["grid voltage", "ac grid", "电网电压", "市电电压"])
        let gridHz = liveValue(rows, ["grid frequency", "电网频率", "市电频率"])
        let outputVoltage = liveValue(rows, ["ac output voltage", "output voltage", "输出电压"], skip: ["second"])
        let outputHz = liveValue(rows, ["ac output frequency", "output frequency", "输出频率"], skip: ["second"])
        let apparent = liveValue(rows, ["apparent", "视在"], skip: ["second"])
        let load = liveValue(rows, ["active power", "output power", "输出功率", "有功"], skip: ["second"])
        let loadPercent = liveValue(rows, ["load percent", "负载百分比", "load %"])
        let batteryVoltage = liveValue(rows, ["battery voltage", "电池电压"])
        let batteryPercent = liveValue(rows, ["battery capacity", "soc", "电池容量"])
        // "Battery Discharging Current" contains "charging current", so the charging lookup has to
        // skip anything with "discharg" in it, as the Node client does.
        let charge = batteryCurrent(rows, exact: ["battery charging current", "battery charge current"],
                                    loose: ["charging current", "充电电流"], skip: ["discharg"])
        let discharge = batteryCurrent(rows, exact: ["battery discharging current", "battery discharge current"],
                                       loose: ["discharge current", "discharging current", "放电电流"], skip: [])
        // The Node client matches PV voltage on a bare "pv1" and PV2 power on a bare "pv2", which
        // would pick the wrong row on a model that lists a PV2 voltage first. Be stricter here.
        let pvVoltage = liveValue(rows, ["pv1 input voltage", "pv1 voltage", "pv input voltage", "pv输入电压"])
        let pv1 = liveValue(rows, ["pv1 input power", "pv1 power", "光伏功率"], skip: ["pv2"])
            ?? liveValue(rows, ["pv input power", "pv power"], skip: ["pv1", "pv2"])
        let pv2 = liveValue(rows, ["pv2 input power", "pv2 power"])

        guard load != nil || batteryVoltage != nil || pv1 != nil || gridVoltage != nil else {
            throw InverterDataError.noReadings
        }

        let logger = collector(in: collectors, pn: device?.pn)
        let zone = timeZone ?? plant?.timeZone ?? device?.timeZone ?? logger.timeZone ?? .current
        // "Timestamp" is when the logger last reported. "Date Time" is the inverter's own clock,
        // which on this unit is hours off, so it is deliberately not used.
        let stamp = rows.first { $0.title.trimmingCharacters(in: .whitespaces).lowercased() == "timestamp" }?
            .value?.stringValue
        let plantName = plant?.name.trimmingCharacters(in: .whitespaces)

        return EnergySnapshot(
            fetchedAt: fetchedAt,
            deviceTime: stamp.flatMap { parseTimestamp($0, in: zone) },
            pvPowerW: (pv1 ?? 0) + (pv2 ?? 0),
            pvVoltage: pvVoltage,
            loadPowerW: load ?? 0,
            loadApparentVA: apparent,
            loadPercent: loadPercent,
            outputVoltage: outputVoltage,
            outputHz: outputHz,
            batteryPercent: batteryPercent,
            batteryVoltage: batteryVoltage,
            batteryChargeA: charge ?? 0,
            batteryDischargeA: discharge ?? 0,
            gridVoltage: gridVoltage,
            gridHz: gridHz,
            ratedPowerW: anyValue(rows, ["ac output rating active", "ac output rated active", "rated active power"]),
            todayKWh: energyKWh(rows, ["today generation", "today", "daily"]),
            monthKWh: energyKWh(rows, ["month generation", "month"]),
            yearKWh: energyKWh(rows, ["year generation", "year"]),
            totalKWh: energyKWh(rows, ["total generation", "total energy", "lifetime"]),
            activeWarning: activeWarning(in: warnings),
            plantName: (plantName?.isEmpty ?? true) ? nil : plantName,
            machineType: text(rows, ["machine type"]),
            collectorOnline: logger.online
        )
    }

    // MARK: Side payloads

    /// Title of the newest warning that has not cleared. `status == false` means cleared; the
    /// cloud lists warnings newest first.
    public static func activeWarning(in warnings: JSONValue?) -> String? {
        guard let warnings else { return nil }
        for warning in warnings["warning"]?.arrayValue ?? warnings.arrayValue ?? [] {
            if warning["status"]?.boolValue == false { continue }
            if let title = warning.firstText("title", "desc", "code") { return title }
        }
        return nil
    }

    /// The plant from `queryPlants`: the one the device belongs to when that is known, else the first.
    public static func plant(in plants: JSONValue?, preferID: Int? = nil) -> PlantInfo? {
        guard let plants else { return nil }
        let list = plants["plant"]?.arrayValue ?? plants.arrayValue ?? []
        let match = preferID.flatMap { id in list.first { $0["pid"]?.intValue == id } }
        guard let hit = match ?? list.first else { return nil }
        let offset = hit["address"]?["timezone"]?.intValue
        return PlantInfo(id: hit["pid"]?.intValue, name: hit["name"]?.stringValue ?? "",
                         timeZone: offset.flatMap { TimeZone(secondsFromGMT: $0) })
    }

    /// Logger state from `webQueryCollectorsEs`. Its `status` uses the vendor's device-status
    /// table (api.dessmonitor.com chapter5/queryDeviceStatus, "deviceStatus"): 0 online and
    /// running normally (also seen live while the logger was reporting), 1 offline, and 2 fault,
    /// 3 standby, 4 warning, 5 error, 6 protocol error, all of which the cloud can only know
    /// about a logger that is connected. A code outside the table is left unknown.
    /// (The Node dashboard labels 1 "Online"; that is a mistake in its display text.)
    static func collector(in collectors: JSONValue?, pn: String?) -> (online: Bool?, timeZone: TimeZone?) {
        guard let collectors else { return (nil, nil) }
        let list = collectors["collector"]?.arrayValue ?? collectors.arrayValue ?? []
        let match = pn.flatMap { pn in list.first { $0["pn"]?.stringValue == pn } }
        guard let hit = match ?? list.first else { return (nil, nil) }
        let online: Bool?
        switch hit["status"]?.intValue {
        case 1: online = false
        case 0, 2, 3, 4, 5, 6: online = true
        default: online = nil
        }
        let zone = hit[any: "timeZone", "timezone"]?.intValue.flatMap { TimeZone(secondsFromGMT: $0) }
        return (online, zone)
    }

    public static func collectorOnline(in collectors: JSONValue?, pn: String? = nil) -> Bool? {
        collector(in: collectors, pn: pn).online
    }

    /// `pickDevice()` in the Node client: the device matching the preferred PN or SN, else the first.
    /// Works on both `webQueryDeviceEs` and the `queryDevices` fallback.
    public static func pickDevice(from devices: JSONValue, preferPN: String? = nil, preferSN: String? = nil) -> DeviceRef? {
        let list = deviceEntries(devices)
        guard let first = list.first else { return nil }
        let hit = list.first { device in
            if let preferPN, device["pn"]?.stringValue == preferPN { return true }
            if let preferSN, device["sn"]?.stringValue == preferSN || device["deviceAlias"]?.stringValue == preferSN { return true }
            return false
        } ?? first
        return deviceRef(hit, preferPN: preferPN, preferSN: preferSN)
    }

    /// Every device in a `webQueryDeviceEs` or `queryDevices` answer.
    public static func allDevices(from devices: JSONValue) -> [DeviceRef] {
        deviceEntries(devices).map { deviceRef($0) }
    }

    private static func deviceEntries(_ devices: JSONValue) -> [JSONValue] {
        devices.arrayValue ?? devices["device"]?.arrayValue
            ?? devices["page"]?["device"]?.arrayValue ?? devices["dat"]?.arrayValue ?? []
    }

    private static func deviceRef(_ hit: JSONValue, preferPN: String? = nil, preferSN: String? = nil) -> DeviceRef {
        DeviceRef(
            pn: hit["pn"]?.nonEmptyString ?? preferPN ?? "",
            sn: hit["sn"]?.nonEmptyString ?? preferSN ?? "",
            devcode: hit[any: "devcode", "devCode"]?.intValue ?? 0,
            devaddr: hit[any: "devaddr", "devAddr"]?.intValue ?? 1,
            alias: hit.firstText("alias", "deviceAlias", "devalias", "name") ?? "",
            plantID: hit["pid"]?.intValue,
            timeZoneOffset: hit[any: "timezone", "timeZone"]?.intValue
        )
    }

    // MARK: Day curve

    /// Builds the chart series from `queryDeviceDataOneDay`, which returns the column titles once
    /// (`title`) and then one `field` array per logger report (`row`). Columns are found by title,
    /// the way `forecast-test/pull-history.mjs` does it. The endpoint returns the whole day in one
    /// answer (295 rows for a full day); it ignores `page` and `pagesize`.
    public static func dayCurve(_ dat: JSONValue, day: String, timeZone: TimeZone, fetchedAt: Date = Date()) throws -> DayCurve {
        let calendar = gregorian(timeZone)
        let dayStart = parseTimestamp("\(day) 00:00:00", calendar: calendar) ?? calendar.startOfDay(for: fetchedAt)
        var curve = DayCurve(day: day, dayStart: dayStart, points: [], fetchedAt: fetchedAt)

        let reports = dat["row"]?.arrayValue ?? []
        guard !reports.isEmpty else { return curve }

        let column = dayColumns(dat)
        guard let timeColumn = column("timestamp") else { throw InverterDataError.missingColumn("Timestamp") }
        let loadColumn = column("ac output active power")
        let pv1Column = column("pv1 input power")
        let pv2Column = column("pv2 input power")
        let batteryColumn = column("battery capacity")
        let voltageColumn = column("battery voltage"), chargeColumn = column("battery charging current")
        let dischargeColumn = column("battery discharging current"), gridColumn = column("grid voltage")

        var byTime: [Date: DayCurvePoint] = [:]
        for report in reports {
            guard let fields = report["field"]?.arrayValue ?? report.arrayValue else { continue }
            func number(_ index: Int?) -> Double? {
                guard let index, fields.indices.contains(index) else { return nil }
                return fields[index].looseNumber
            }
            guard fields.indices.contains(timeColumn), let stamp = fields[timeColumn].stringValue,
                  let time = parseTimestamp(stamp, calendar: calendar) else { continue }
            let reading = EnergySnapshot(
                pvPowerW: (number(pv1Column) ?? 0) + (number(pv2Column) ?? 0), loadPowerW: number(loadColumn) ?? 0,
                batteryVoltage: number(voltageColumn), batteryChargeA: number(chargeColumn) ?? 0,
                batteryDischargeA: number(dischargeColumn) ?? 0, gridVoltage: number(gridColumn))
            byTime[time] = DayCurvePoint(time: time, pvW: reading.pvPowerW, loadW: reading.loadPowerW,
                                         gridW: reading.gridPowerW, batteryPercent: number(batteryColumn))
        }
        curve.points = byTime.values.sorted { $0.time < $1.time }
        return curve
    }

    /// Finds a column of `queryDeviceDataOneDay` by title.
    private static func dayColumns(_ dat: JSONValue) -> (String) -> Int? {
        let titles = (dat["title"]?.arrayValue ?? []).map {
            ($0["title"]?.stringValue ?? $0.stringValue ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        }
        return { name in
            titles.firstIndex(of: name)
                ?? titles.firstIndex(where: { $0.contains(name) && !isNameplate($0) && !$0.contains("second") })
        }
    }

    /// Adds up one day of reports into kWh, the same way as `DayCurve.totals`. The last report
    /// counts for five minutes, or until `now` while the day is still going. Nil if the day has no reports.
    public static func dayTotals(_ dat: JSONValue, day: String, timeZone: TimeZone, complete: Bool, now: Date = Date()) throws -> DayTotals? {
        let curve = try dayCurve(dat, day: day, timeZone: timeZone, fetchedAt: now)
        guard let last = curve.points.last else { return nil }
        let sum = curve.totals(now: complete ? last.time.addingTimeInterval(300) : now)
        return DayTotals(day: day, solarKWh: sum.solarKWh, gridKWh: sum.gridKWh, loadKWh: sum.loadKWh, complete: complete)
    }

    // MARK: Time

    /// The plant's calendar day containing `date`, as the API wants it: "2026-10-13".
    public static func dayString(for date: Date, in timeZone: TimeZone) -> String {
        let parts = gregorian(timeZone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Parses the cloud's "2026-10-13 17:22:30" (a "T" separator and fractional seconds are tolerated).
    public static func parseTimestamp(_ text: String, in timeZone: TimeZone) -> Date? {
        parseTimestamp(text, calendar: gregorian(timeZone))
    }

    static func parseTimestamp(_ text: String, calendar: Calendar) -> Date? {
        let halves = text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0 == " " || $0 == "T" })
        guard halves.count == 2 else { return nil }
        let date = halves[0].split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        let time = halves[1].split(separator: ":", omittingEmptySubsequences: false).map { Double($0) }
        guard date.count == 3, time.count == 2 || time.count == 3,
              let year = date[0], let month = date[1], let day = date[2],
              let hour = time[0], let minute = time[1], let second = time.count == 3 ? time[2] : 0,
              (1...12).contains(month), (1...31).contains(day),
              (0..<24).contains(hour), (0..<60).contains(minute), (0..<61).contains(second),
              hour == hour.rounded(), minute == minute.rounded() else { return nil }
        var parts = DateComponents()
        parts.year = year; parts.month = month; parts.day = day
        parts.hour = Int(hour); parts.minute = Int(minute); parts.second = Int(second)
        return calendar.date(from: parts)
    }

    private static func gregorian(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
