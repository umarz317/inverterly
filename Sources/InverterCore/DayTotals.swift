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
    /// Estimated energy sent to the grid (see `EnergySnapshot.exportPowerW`). Zero on a model that
    /// cannot export. Nil only in entries saved before it was estimated, which are read again.
    public var exportKWh: Double?

    public var id: String { day }

    public init(day: String, solarKWh: Double, gridKWh: Double, loadKWh: Double, complete: Bool, exportKWh: Double? = 0) {
        self.day = day; self.solarKWh = solarKWh; self.gridKWh = gridKWh; self.loadKWh = loadKWh; self.complete = complete
        self.exportKWh = exportKWh
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
    public var exportKWh: Double

    public var id: String { month }

    /// Groups days by month, newest month first.
    public static func monthly(_ days: some Sequence<DayTotals>) -> [MonthTotals] {
        var byMonth: [String: MonthTotals] = [:]
        for day in days {
            let month = String(day.day.prefix(7))
            var total = byMonth[month] ?? MonthTotals(month: month, days: 0, solarKWh: 0, gridKWh: 0, loadKWh: 0, exportKWh: 0)
            total.days += 1
            total.solarKWh += day.solarKWh; total.gridKWh += day.gridKWh; total.loadKWh += day.loadKWh
            total.exportKWh += day.exportKWh ?? 0
            byMonth[month] = total
        }
        return byMonth.values.sorted { $0.month > $1.month }
    }
}

/// Daily totals kept on disk, so a finished day is read from the cloud only once.
/// `~/Library/Application Support/Inverterly/history.json`.
public struct HistoryStore: Sendable {
    public let fileURL: URL?

    public init(fileURL: URL?) { self.fileURL = fileURL }

    public static let standard = HistoryStore(fileURL: appSupportFile("history.json"))

    /// Keeps the history in memory only.
    public static let memoryOnly = HistoryStore(fileURL: nil)

    func load() -> [String: DayTotals] {
        guard let fileURL, let data = FileManager.default.contents(atPath: fileURL.path) else { return [:] }
        // Keys are "<inverter serial>/<day>". Entries from before there was more than one inverter have no serial.
        let all = (try? JSONDecoder().decode([String: DayTotals].self, from: data)) ?? [:]
        // Days saved before export was estimated have no figure; dropping them reads those days once more.
        return all.filter { $0.key.contains("/") && $0.value.exportKWh != nil }
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
