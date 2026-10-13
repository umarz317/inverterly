import XCTest
import InverterCore
@testable import InverterUI

/// A provider with a fixed run of days: each has solar equal to its day of the month.
private struct DaysProvider: SnapshotProviding {
    let first: String        // the earliest day that has data, "2026-09-20"
    func fetchSnapshot(force: Bool) async throws -> EnergySnapshot { EnergySnapshot() }
    func fetchToday() async throws -> DayCurve { DayCurve(day: "", dayStart: Date()) }
    func fetchDayTotals(day: String) async throws -> DayTotals? {
        try await Task.sleep(for: .milliseconds(5))
        guard day >= first else { return nil }
        let solar = Double(day.suffix(2)) ?? 0
        return DayTotals(day: day, solarKWh: solar, gridKWh: 1, loadKWh: solar + 1, complete: true)
    }
}

@MainActor
final class HistoryTests: XCTestCase {
    private func store(first: String) -> AppStore {
        AppStore(provider: DaysProvider(first: first), defaults: UserDefaults(suiteName: "InverterUITests-\(UUID().uuidString)")!)
    }

    private func today() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    func testDaysTabReadsEveryDayOfThisMonthSoFar() async {
        let store = store(first: "2000-01-01")
        await store.loadHistory(force: true)
        let dayOfMonth = Int(today().suffix(2))!
        XCTAssertEqual(store.currentMonthDays.count, dayOfMonth)
        XCTAssertEqual(store.currentMonthDays.first?.day, today(), "newest first")
        XCTAssertFalse(store.historyLoading)
        XCTAssertNil(store.historyError)
    }

    func testMonthsTabStopsAtTheFirstMonthWithNothing() async {
        // Data from the start of the previous month only.
        let earliest = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        let store = store(first: formatter.string(from: earliest) + "-01")
        store.historyTab = .months
        await store.loadHistory(force: true)
        XCTAssertEqual(store.months.count, 2, "this month and the one before; the third has nothing")
    }
}
