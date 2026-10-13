#if DEBUG
import Foundation
import InverterCore

/// Made-up readings for a sunny afternoon, for working on the layout with `-demo`.
struct DemoProvider: SnapshotProviding {
    func fetchSnapshot(force: Bool) async throws -> EnergySnapshot {
        // `-slow` holds the reading back, to look at the loading screen.
        if CommandLine.arguments.contains("-slow") { try await Task.sleep(for: .seconds(20)) }
        return EnergySnapshot(deviceTime: Date().addingTimeInterval(-90),
                       pvPowerW: 3420, pvVoltage: 312,
                       loadPowerW: 1180, loadApparentVA: 1290, loadPercent: 20,
                       outputVoltage: 230, outputHz: 50,
                       batteryPercent: 78, batteryVoltage: 53.4, batteryChargeA: 38,
                       gridVoltage: 236, gridHz: 50, ratedPowerW: 6000,
                       todayKWh: 14.2, machineType: "Hybrid 6 kW", collectorOnline: true)
    }

    func fetchToday() async throws -> DayCurve {
        let start = Calendar.current.startOfDay(for: Date())
        // At least to late afternoon, so the chart has a day's shape whatever the clock says.
        let now = max(Date().timeIntervalSince(start), 17.5 * 3600)
        let points = stride(from: 0.0, through: now, by: 300).map { t -> DayCurvePoint in
            let hour = t / 3600
            let sun = max(0, sin((hour - 6) / 13 * .pi)) * 4200
            let load = 600 + 500 * max(0, sin((hour - 6) / 4)) + (hour > 18 ? 900 : 0)
            let battery = hour < 8 ? 62 - hour * 3 : min(100, 38 + (hour - 8) * 8)
            return DayCurvePoint(time: start.addingTimeInterval(t), pvW: sun, loadW: load,
                                 gridW: sun < load && (hour < 6 || hour > 21) ? load - sun : 0, batteryPercent: battery)
        }
        return DayCurve(day: Self.key(Date(), "yyyy-MM-dd"), dayStart: start, points: points)
    }

    func fetchDayTotals(day: String) async throws -> DayTotals? {
        let seed = Double(day.hashValue % 1000) / 1000
        let isToday = day == Self.key(Date(), "yyyy-MM-dd")
        return DayTotals(day: day, solarKWh: 14 + 8 * abs(seed), gridKWh: 2 + 4 * abs(seed - 0.5),
                         loadKWh: 18 + 3 * abs(seed), complete: !isToday)
    }

    func listDevices() async throws -> [DeviceInfo] {
        [DeviceInfo(id: "A", name: "Roof inverter", isSelected: true), DeviceInfo(id: "B", name: "Garage inverter")]
    }

    func selectDevice(_ id: String) async {}
    func reset() async {}

    private static func key(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
#endif
