import Foundation
import InverterCore

// Prints one live reading and the size of today's curve. Read-only: it only sends queries.
// The output is safe to paste anywhere: no password, token, serial number or stick PN.
//
//   swift run InverterProbe                    account from INVERTERBAR_ENV / the envPath default / ~/.config/inverterbar/.env
//   swift run InverterProbe /path/to/.env      account from this file
//   swift run InverterProbe --memory           do not read or write the saved session file
//   swift run InverterProbe --session <file>   keep the session in this file instead of the app's own

var envPath: String?
var store = SessionStore.standard
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    if argument == "--memory" {
        store = .memoryOnly
    } else if argument == "--session", !arguments.isEmpty {
        store = SessionStore(fileURL: URL(fileURLWithPath: (arguments.removeFirst() as NSString).expandingTildeInPath))
    } else {
        envPath = argument
    }
}

/// Counts what goes out, by action name only. The URL (it carries the token) is never kept or printed.
final class Tally: HTTPTransport, @unchecked Sendable {
    private let inner = URLSessionTransport()
    private let lock = NSLock()
    private var sent: [String] = []

    func get(_ url: URL) async throws -> (status: Int, body: Data) {
        let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "action" }?.value ?? "?"
        lock.withLock { sent.append(name) }
        return try await inner.get(url)
    }

    /// "authSource x1, queryPlants x1, ...", in the order each action was first sent.
    var summary: String {
        let all = lock.withLock { sent }
        var order: [String] = []
        for name in all where !order.contains(name) { order.append(name) }
        return order.map { name in "\(name) x\(all.filter { $0 == name }.count)" }.joined(separator: ", ")
    }
}

func line(_ label: String, _ value: String) {
    print(label.padding(toLength: 14, withPad: " ", startingAt: 0) + value)
}

func number(_ value: Double?, _ unit: String, digits: Int = 1) -> String {
    guard let value else { return "n/a" }
    return String(format: "%.\(digits)f", value) + (unit.isEmpty ? "" : " " + unit)
}

func clock(_ date: Date, _ format: String = "yyyy-MM-dd HH:mm:ss Z") -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = format
    return formatter.string(from: date)
}

let tally = Tally()
let service = InverterService(envPath: envPath, sessionStore: store, transport: tally)
let started = Date()

do {
    let s = try await service.fetchSnapshot()
    let tookMs = Int(Date().timeIntervalSince(started) * 1000)

    print("InverterBar probe (read-only), fetched in \(tookMs) ms")
    line("plant", s.plantName ?? "n/a")
    line("machine", s.machineType ?? "n/a")
    if let deviceTime = s.deviceTime {
        let age = Int(Date().timeIntervalSince(deviceTime))
        line("logger time", "\(clock(deviceTime)), \(age) s ago\(s.isStale() ? " (STALE)" : "")")
    } else {
        line("logger time", "n/a")
    }
    line("logger", s.collectorOnline.map { $0 ? "online" : "offline" } ?? "unknown")
    line("mode", s.mode.label)
    line("solar", "\(PowerFormat.watts(s.pvPowerW))  (PV \(number(s.pvVoltage, "V")))")
    line("load", "\(PowerFormat.watts(s.loadPowerW))  (\(number(s.loadApparentVA, "VA", digits: 0)), \(number(s.loadPercent, "%", digits: 0)))")
    line("output", "\(number(s.outputVoltage, "V")), \(number(s.outputHz, "Hz"))")
    line("battery", "\(number(s.batteryPercent, "%", digits: 0)), \(number(s.batteryVoltage, "V")), charge \(number(s.batteryChargeA, "A", digits: 0)), discharge \(number(s.batteryDischargeA, "A", digits: 0)), \(s.batteryPowerW < 0 ? "-" : "+")\(PowerFormat.watts(s.batteryPowerW))")
    line("grid", "\(number(s.gridVoltage, "V")), \(number(s.gridHz, "Hz")), drawing \(PowerFormat.watts(s.gridPowerW))")
    line("rated", number(s.ratedPowerW, "W", digits: 0))
    line("energy", "today \(number(s.todayKWh, "kWh", digits: 3)), month \(number(s.monthKWh, "kWh", digits: 3)), year \(number(s.yearKWh, "kWh", digits: 3)), total \(number(s.totalKWh, "kWh", digits: 3))")
    line("warning", s.activeWarning ?? "none active")

    let cachedAgain = try await service.fetchSnapshot()
    print("")
    line("cache", cachedAgain == s ? "second call answered from the 20 s cache" : "second call fetched again (unexpected)")

    let curve = try await service.fetchToday()
    if let first = curve.points.first, let last = curve.points.last {
        line("today curve", "\(curve.points.count) points for \(curve.day), \(clock(first.time, "HH:mm")) to \(clock(last.time, "HH:mm")), peak PV \(PowerFormat.watts(curve.peakPvW)), peak load \(PowerFormat.watts(curve.peakLoadW))")
        line("last point", "\(clock(last.time, "HH:mm:ss")) pv \(PowerFormat.watts(last.pvW)), load \(PowerFormat.watts(last.loadW)), battery \(number(last.batteryPercent, "%", digits: 0))")
    } else {
        line("today curve", "0 points for \(curve.day) (nothing reported yet today)")
    }

    // Yesterday and today added up (solar, estimated grid, load).
    for offset in [-1, 0] {
        let day = SnapshotParser.dayString(for: Date().addingTimeInterval(Double(offset) * 86_400), in: .current)
        if let totals = try await service.fetchDayTotals(day: day) {
            line("day", String(format: "\(day) solar %.2f kWh, grid %.2f kWh (estimated), load %.2f kWh%@",
                                      totals.solarKWh, totals.gridKWh, totals.loadKWh, totals.complete ? "" : " (so far)"))
        }
    }

    // The same keys Tools/node-reading.mjs prints from the Node client, for Tools/compare-live.sh.
    print("")
    print("node equivalents:")
    // The logger's report time as the cloud wrote it: wall-clock time at the plant. The curve's
    // dayStart is the plant's midnight, which gives that without knowing the plant's zone here.
    var stamp = "null"
    if let deviceTime = s.deviceTime {
        let sinceMidnight = Int(deviceTime.timeIntervalSince(curve.dayStart).rounded())
        if (0..<86_400).contains(sinceMidnight) {
            stamp = String(format: "%@ %02d:%02d:%02d", curve.day, sinceMidnight / 3600, sinceMidnight / 60 % 60, sinceMidnight % 60)
        }
    }
    print("  timestamp=\(stamp)")
    let pairs: [(String, Double?)] = [
        ("grid_voltage_v", s.gridVoltage), ("grid_frequency_hz", s.gridHz),
        ("ac_output_voltage_v", s.outputVoltage), ("ac_output_frequency_hz", s.outputHz),
        ("ac_output_apparent_power_va", s.loadApparentVA), ("ac_output_active_power_w", s.loadPowerW),
        ("output_load_percent", s.loadPercent), ("battery_voltage_v", s.batteryVoltage),
        ("battery_capacity_percent", s.batteryPercent), ("battery_charging_current_a", s.batteryChargeA),
        ("battery_discharge_current_a", s.batteryDischargeA), ("pv1_input_voltage_v", s.pvVoltage),
        ("pv1_plus_pv2_input_power_w", s.pvPowerW),
        ("today_kwh", s.todayKWh), ("month_kwh", s.monthKWh), ("year_kwh", s.yearKWh), ("total_kwh", s.totalKWh),
        ("rated_power_w", s.ratedPowerW),
    ]
    for (key, value) in pairs {
        print("  \(key)=\(value.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? "null")")
    }
    print("  machine_type=\(s.machineType ?? "null")")
    print("  plant=\(s.plantName ?? "null")")
    print("  active_warnings=\(s.activeWarning == nil ? 0 : 1)")

    print("")
    line("sent", tally.summary)
} catch {
    // Errors from InverterCore never carry the request URL, the token or the password.
    FileHandle.standardError.write(Data("probe failed: \(error.localizedDescription)\nsent: \(tally.summary)\n".utf8))
    exit(1)
}
