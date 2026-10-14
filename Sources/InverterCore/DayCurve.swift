import Foundation

/// One logger report (about every 5 minutes) reduced to what a small chart needs.
public struct DayCurvePoint: Sendable, Equatable, Identifiable {
    public var time: Date
    /// PV1 + PV2 input power, watts.
    public var pvW: Double
    /// AC output active power, watts.
    public var loadW: Double
    /// Estimated grid draw, watts, worked out like `EnergySnapshot.gridPowerW`.
    public var gridW: Double
    public var batteryPercent: Double?
    /// Estimated power sent to the grid, watts, worked out like `EnergySnapshot.exportPowerW`.
    public var exportW: Double

    public var id: Date { time }

    public init(time: Date, pvW: Double, loadW: Double, gridW: Double = 0, batteryPercent: Double? = nil, exportW: Double = 0) {
        self.time = time; self.pvW = pvW; self.loadW = loadW; self.gridW = gridW; self.batteryPercent = batteryPercent
        self.exportW = exportW
    }
}

/// Today's readings in time order. Empty right after midnight, before the first report of the day.
public struct DayCurve: Sendable, Equatable {
    /// The plant's calendar day, "2026-10-13".
    public var day: String
    /// Midnight at the start of `day` in the plant's time zone; the chart's x axis runs 24 h from here.
    public var dayStart: Date
    public var points: [DayCurvePoint]
    public var fetchedAt: Date

    public init(day: String, dayStart: Date, points: [DayCurvePoint] = [], fetchedAt: Date = Date()) {
        self.day = day; self.dayStart = dayStart; self.points = points; self.fetchedAt = fetchedAt
    }

    public var isEmpty: Bool { points.isEmpty }
    public var dayEnd: Date { dayStart.addingTimeInterval(24 * 3600) }
    public var peakPvW: Double { points.map(\.pvW).max() ?? 0 }
    public var peakLoadW: Double { points.map(\.loadW).max() ?? 0 }
    public var peakGridW: Double { points.map(\.gridW).max() ?? 0 }
    public var latest: DayCurvePoint? { points.last }

    /// Energy so far today, in kWh, added up the same way as `SnapshotParser.dayTotals`: each reading
    /// counts until the next one, at most ten minutes, and the last one until `now`, at most five.
    public func totals(now: Date = Date()) -> (solarKWh: Double, gridKWh: Double, loadKWh: Double, exportKWh: Double) {
        var solar = 0.0, grid = 0.0, load = 0.0, export = 0.0
        for (index, point) in points.enumerated() {
            let seconds = index + 1 < points.count
                ? min(points[index + 1].time.timeIntervalSince(point.time), 600)
                : min(300, max(0, now.timeIntervalSince(point.time)))
            let hours = seconds / 3600
            solar += max(0, point.pvW) * hours
            grid += point.gridW * hours
            load += max(0, point.loadW) * hours
            export += point.exportW * hours
        }
        return (solar / 1000, grid / 1000, load / 1000, export / 1000)
    }

    /// Position of a moment along the day, 0 at midnight and 1 at the next midnight.
    public func fraction(of time: Date) -> Double {
        time.timeIntervalSince(dayStart) / (24 * 3600)
    }
}
