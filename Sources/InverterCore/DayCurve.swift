import Foundation

/// One logger report (about every 5 minutes) reduced to what a small chart needs.
public struct DayCurvePoint: Sendable, Equatable, Identifiable {
    public var time: Date
    /// PV1 + PV2 input power, watts.
    public var pvW: Double
    /// AC output active power, watts.
    public var loadW: Double
    public var batteryPercent: Double?

    public var id: Date { time }

    public init(time: Date, pvW: Double, loadW: Double, batteryPercent: Double? = nil) {
        self.time = time; self.pvW = pvW; self.loadW = loadW; self.batteryPercent = batteryPercent
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
    public var latest: DayCurvePoint? { points.last }

    /// Position of a moment along the day, 0 at midnight and 1 at the next midnight.
    public func fraction(of time: Date) -> Double {
        time.timeIntervalSince(dayStart) / (24 * 3600)
    }
}
