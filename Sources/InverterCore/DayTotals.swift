import Foundation

/// What one day came to, in kWh: solar made, grid drawn and load served. Grid is estimated from
/// the logger's readings the same way as the live grid figure (see `EnergySnapshot.gridPowerW`).
public struct DayTotals: Codable, Sendable, Equatable, Identifiable {
    /// The plant's calendar day, "2026-10-13".
    public var day: String
    public var solarKWh: Double
    public var gridKWh: Double
    public var loadKWh: Double
    /// False for a day that was still going when it was read; those are read again.
    public var complete: Bool

    public var id: String { day }

    public init(day: String, solarKWh: Double, gridKWh: Double, loadKWh: Double, complete: Bool) {
        self.day = day; self.solarKWh = solarKWh; self.gridKWh = gridKWh; self.loadKWh = loadKWh; self.complete = complete
    }
}

/// The days of one month added up.
public struct MonthTotals: Sendable, Equatable, Identifiable {
    /// "2026-10"
    public var month: String
    public var days: Int
    public var solarKWh: Double
    public var gridKWh: Double
    public var loadKWh: Double

    public var id: String { month }

    /// Groups days by month, newest month first.
    public static func monthly(_ days: some Sequence<DayTotals>) -> [MonthTotals] {
        var byMonth: [String: MonthTotals] = [:]
        for day in days {
            let month = String(day.day.prefix(7))
            var total = byMonth[month] ?? MonthTotals(month: month, days: 0, solarKWh: 0, gridKWh: 0, loadKWh: 0)
            total.days += 1
            total.solarKWh += day.solarKWh; total.gridKWh += day.gridKWh; total.loadKWh += day.loadKWh
            byMonth[month] = total
        }
        return byMonth.values.sorted { $0.month > $1.month }
    }
}

/// Daily totals kept on disk, so a finished day is read from the cloud only once.
/// `~/Library/Application Support/InverterBar/history.json`.
public struct HistoryStore: Sendable {
    public let fileURL: URL?

    public init(fileURL: URL?) { self.fileURL = fileURL }

    public static let standard: HistoryStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return HistoryStore(fileURL: base.appendingPathComponent("InverterBar", isDirectory: true)
            .appendingPathComponent("history.json", isDirectory: false))
    }()

    /// Keeps the history in memory only.
    public static let memoryOnly = HistoryStore(fileURL: nil)

    func load() -> [String: DayTotals] {
        guard let fileURL, let data = FileManager.default.contents(atPath: fileURL.path) else { return [:] }
        return (try? JSONDecoder().decode([String: DayTotals].self, from: data)) ?? [:]
    }

    func save(_ days: [String: DayTotals]) {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // A history that cannot be saved still works for this run; it is just read again next time.
        if let data = try? encoder.encode(days) { try? writePrivately(data, to: fileURL) }
    }

    func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
