import Foundation

/// What is carrying the load right now. The vendor feed has no mode row for this inverter,
/// so this is inferred from the power balance (see `EnergySnapshot.mode`).
public enum InverterMode: String, Sendable, Equatable, CaseIterable {
    case solar      // PV covers the load (and may be charging the battery)
    case battery    // battery is discharging into the load
    case grid       // grid is carrying the load (and may be charging the battery)
    case standby    // nothing is drawing power
    case unknown

    public var label: String {
        switch self {
        case .solar: "On solar"
        case .battery: "On battery"
        case .grid: "On grid"
        case .standby: "Standby"
        case .unknown: "Unknown"
        }
    }
}

/// One reading of the inverter, already converted to plain numbers.
/// Powers are watts, energies are kWh. Read-only: nothing here can change a setting.
public struct EnergySnapshot: Sendable, Equatable {
    public var fetchedAt: Date
    /// When the Wi-Fi logger last reported to the vendor cloud (it reports about every 5 minutes).
    public var deviceTime: Date?

    public var pvPowerW: Double
    public var pvVoltage: Double?

    public var loadPowerW: Double
    public var loadApparentVA: Double?
    public var loadPercent: Double?
    public var outputVoltage: Double?
    public var outputHz: Double?

    public var batteryPercent: Double?
    public var batteryVoltage: Double?
    public var batteryChargeA: Double
    public var batteryDischargeA: Double

    public var gridVoltage: Double?
    public var gridHz: Double?

    public var ratedPowerW: Double?

    public var todayKWh: Double?
    public var monthKWh: Double?
    public var yearKWh: Double?
    public var totalKWh: Double?

    /// Title of a warning that is active right now, nil when there is none.
    public var activeWarning: String?
    public var plantName: String?
    public var machineType: String?
    public var collectorOnline: Bool?

    public init(
        fetchedAt: Date = Date(), deviceTime: Date? = nil,
        pvPowerW: Double = 0, pvVoltage: Double? = nil,
        loadPowerW: Double = 0, loadApparentVA: Double? = nil, loadPercent: Double? = nil,
        outputVoltage: Double? = nil, outputHz: Double? = nil,
        batteryPercent: Double? = nil, batteryVoltage: Double? = nil,
        batteryChargeA: Double = 0, batteryDischargeA: Double = 0,
        gridVoltage: Double? = nil, gridHz: Double? = nil, ratedPowerW: Double? = nil,
        todayKWh: Double? = nil, monthKWh: Double? = nil, yearKWh: Double? = nil, totalKWh: Double? = nil,
        activeWarning: String? = nil, plantName: String? = nil, machineType: String? = nil, collectorOnline: Bool? = nil
    ) {
        self.fetchedAt = fetchedAt; self.deviceTime = deviceTime
        self.pvPowerW = pvPowerW; self.pvVoltage = pvVoltage
        self.loadPowerW = loadPowerW; self.loadApparentVA = loadApparentVA; self.loadPercent = loadPercent
        self.outputVoltage = outputVoltage; self.outputHz = outputHz
        self.batteryPercent = batteryPercent; self.batteryVoltage = batteryVoltage
        self.batteryChargeA = batteryChargeA; self.batteryDischargeA = batteryDischargeA
        self.gridVoltage = gridVoltage; self.gridHz = gridHz; self.ratedPowerW = ratedPowerW
        self.todayKWh = todayKWh; self.monthKWh = monthKWh; self.yearKWh = yearKWh; self.totalKWh = totalKWh
        self.activeWarning = activeWarning; self.plantName = plantName; self.machineType = machineType
        self.collectorOnline = collectorOnline
    }

    /// Battery power in watts. Positive while charging, negative while discharging.
    public var batteryPowerW: Double {
        (batteryChargeA - batteryDischargeA) * (batteryVoltage ?? 0)
    }

    public var gridPresent: Bool { (gridVoltage ?? 0) > 90 }

    /// Grid power is not reported, so it is whatever the load and battery charging need
    /// beyond what PV and battery discharge supply. Battery current is reported in whole amps
    /// (about 50 W per step at 48 V), so small positive balances are treated as rounding.
    ///
    /// While the battery is discharging the inverter is in battery mode and takes nothing from
    /// the grid, even with grid voltage present, so the balance is not consulted at all then:
    /// it is only measurement error. (Seen live: load 1281 W against 23 A at 52.7 V left +69 W,
    /// just over the rounding floor, and showed a grid flow while "On battery".)
    public var gridPowerW: Double {
        guard gridPresent, batteryDischargeA <= 0.4 else { return 0 }
        let balance = loadPowerW + batteryPowerW - pvPowerW
        let floor = max(60, loadPowerW * 0.05)
        return balance > floor ? balance : 0
    }

    /// Only a model that reports itself as a "Grid Tie" can send power to the grid. "Off Grid Tie"
    /// cannot, and an unknown model is assumed not to.
    public var canExport: Bool {
        guard let type = machineType?.lowercased() else { return false }
        return type.contains("grid tie") && !type.contains("off grid")
    }

    /// Power sent to the grid, in watts: an estimate, not a reading. The cloud has no export figure
    /// for these inverters (`grid_active_power` is always 0), so it is what the panels make beyond
    /// the load and the battery's charging, less an assumed conversion loss (the panels are measured
    /// at the DC input, the load at the AC output). A small surplus is treated as measurement
    /// error, like the grid draw. Check it against the meter before relying on it.
    public var exportPowerW: Double {
        guard canExport, gridPresent, pvPowerW > 0 else { return 0 }
        let net = pvPowerW - loadPowerW - batteryPowerW - pvPowerW * Self.conversionLoss
        return net > Self.exportFloorW ? net : 0
    }

    /// Assumed share of the panels' power lost converting DC to AC. An estimate, not a measurement.
    static let conversionLoss = 0.05
    /// Surpluses at or below this many watts count as rounding in the battery current and the readings.
    static let exportFloorW = 60.0

    public var mode: InverterMode {
        if batteryDischargeA > 0.4 { return .battery }
        if gridPowerW > 0 { return .grid }
        if pvPowerW > 20 { return .solar }
        if loadPowerW < 20 { return .standby }
        return .unknown
    }

    public var flows: EnergyFlows {
        EnergyFlows(solarW: max(0, pvPowerW), gridW: gridPowerW, batteryW: batteryPowerW, loadW: max(0, loadPowerW),
                    exportW: exportPowerW)
    }

    /// True when the logger's last report is older than `seconds`.
    public func isStale(after seconds: TimeInterval = 15 * 60, now: Date = Date()) -> Bool {
        guard let deviceTime else { return false }
        return now.timeIntervalSince(deviceTime) > seconds
    }
}

/// The power flows the UI animates. `batteryW` is signed: positive charges the battery. `exportW`
/// goes to the grid, where `gridW` comes from it.
public struct EnergyFlows: Sendable, Equatable {
    public var solarW: Double
    public var gridW: Double
    public var batteryW: Double
    public var loadW: Double
    public var exportW: Double

    public init(solarW: Double = 0, gridW: Double = 0, batteryW: Double = 0, loadW: Double = 0, exportW: Double = 0) {
        self.solarW = solarW; self.gridW = gridW; self.batteryW = batteryW; self.loadW = loadW; self.exportW = exportW
    }

    public static let zero = EnergyFlows()

    public var batteryChargeW: Double { max(0, batteryW) }
    public var batteryDischargeW: Double { max(0, -batteryW) }

    public func mix(_ other: EnergyFlows, _ t: Double) -> EnergyFlows {
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        return EnergyFlows(solarW: lerp(solarW, other.solarW), gridW: lerp(gridW, other.gridW),
                           batteryW: lerp(batteryW, other.batteryW), loadW: lerp(loadW, other.loadW),
                           exportW: lerp(exportW, other.exportW))
    }
}

public enum PowerFormat {
    /// "35 W", "1.14 kW", "12.4 kW".
    public static func watts(_ value: Double) -> String {
        let v = abs(value)
        if v < 1000 { return "\(Int(v.rounded())) W" }
        return String(format: v < 10_000 ? "%.2f kW" : "%.1f kW", v / 1000)
    }

    /// Number and unit apart, for big numerals: ("1.14", "kW").
    public static func split(_ value: Double) -> (number: String, unit: String) {
        let v = abs(value)
        if v < 1000 { return ("\(Int(v.rounded()))", "W") }
        return (String(format: v < 10_000 ? "%.2f" : "%.1f", v / 1000), "kW")
    }

    public static func kWh(_ value: Double) -> String { kWhNumber(value) + " kWh" }

    /// The number alone, for tables headed "kWh": one decimal below 100, none above.
    public static func kWhNumber(_ value: Double) -> String {
        value < 100 ? String(format: "%.1f", value) : String(format: "%.0f", value)
    }
}
