import Foundation
import InverterCore

/// Fixed situations used by the lab and by `--demo`. Numbers are shaped like this site's real
/// readings: a 6 kW off-grid inverter on a 48 V battery.
public struct HeroScenario: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let snapshot: EnergySnapshot?
    /// Flows that were showing before this reading arrived (drives the ramp).
    public let previous: EnergyFlows

    public static let reference = Date(timeIntervalSinceReferenceDate: 780_000_000)

    public func frame() -> HeroFrame {
        HeroFrame(snapshot: snapshot, previous: previous, changedAt: Self.reference)
    }

    public static let sunnyCharging = HeroScenario(
        id: "sunny", title: "Midday: solar runs the load and charges the battery",
        snapshot: EnergySnapshot(
            fetchedAt: reference, deviceTime: reference.addingTimeInterval(-120),
            pvPowerW: 3420, pvVoltage: 286, loadPowerW: 1980, loadApparentVA: 2150, loadPercent: 36,
            outputVoltage: 230.1, outputHz: 50, batteryPercent: 64, batteryVoltage: 54.2,
            batteryChargeA: 24, batteryDischargeA: 0, gridVoltage: 232, gridHz: 49.9, ratedPowerW: 6000,
            todayKWh: 14.2, monthKWh: 322.6, yearKWh: 5408.7, totalKWh: 9984.9, plantName: "PLANT",
            machineType: "Off Grid Tie", collectorOnline: true),
        previous: EnergyFlows(solarW: 600, gridW: 0, batteryW: -900, loadW: 1500))

    public static let eveningBattery = HeroScenario(
        id: "evening", title: "Evening: battery carries the load, PV almost gone",
        snapshot: EnergySnapshot(
            fetchedAt: reference, deviceTime: reference.addingTimeInterval(-200),
            pvPowerW: 35, pvVoltage: 119.9, loadPowerW: 1139, loadApparentVA: 1379, loadPercent: 22,
            outputVoltage: 229.9, outputHz: 49.9, batteryPercent: 86, batteryVoltage: 52.8,
            batteryChargeA: 0, batteryDischargeA: 22, gridVoltage: 233.7, gridHz: 49.9, ratedPowerW: 6000,
            todayKWh: 22.99, monthKWh: 322.6, yearKWh: 5408.7, totalKWh: 9984.9, plantName: "PLANT",
            machineType: "Off Grid Tie", collectorOnline: true),
        previous: EnergyFlows(solarW: 900, gridW: 0, batteryW: 300, loadW: 600))

    public static let nightGrid = HeroScenario(
        id: "night", title: "Night: grid runs the load and charges a low battery",
        snapshot: EnergySnapshot(
            fetchedAt: reference, deviceTime: reference.addingTimeInterval(-60),
            pvPowerW: 0, pvVoltage: 0, loadPowerW: 820, loadApparentVA: 930, loadPercent: 15,
            outputVoltage: 231, outputHz: 50, batteryPercent: 31, batteryVoltage: 50.1,
            batteryChargeA: 20, batteryDischargeA: 0, gridVoltage: 229, gridHz: 50, ratedPowerW: 6000,
            todayKWh: 19.4, monthKWh: 322.6, yearKWh: 5408.7, totalKWh: 9984.9, plantName: "PLANT",
            machineType: "Off Grid Tie", collectorOnline: true),
        previous: EnergyFlows(solarW: 0, gridW: 0, batteryW: -850, loadW: 820))

    public static let outageLowBattery = HeroScenario(
        id: "outage", title: "Outage: no grid, battery at 12% and draining hard",
        snapshot: EnergySnapshot(
            fetchedAt: reference, deviceTime: reference.addingTimeInterval(-90),
            pvPowerW: 0, pvVoltage: 0, loadPowerW: 2650, loadApparentVA: 2900, loadPercent: 48,
            outputVoltage: 228, outputHz: 50, batteryPercent: 12, batteryVoltage: 47.9,
            batteryChargeA: 0, batteryDischargeA: 57, gridVoltage: 0, gridHz: 0, ratedPowerW: 6000,
            todayKWh: 8.1, monthKWh: 322.6, yearKWh: 5408.7, totalKWh: 9984.9,
            activeWarning: "Line fail", plantName: "PLANT", machineType: "Off Grid Tie", collectorOnline: true),
        previous: EnergyFlows(solarW: 0, gridW: 2700, batteryW: 0, loadW: 2650))

    public static let standby = HeroScenario(
        id: "standby", title: "Standby: nothing flowing, battery full",
        snapshot: EnergySnapshot(
            fetchedAt: reference, deviceTime: reference.addingTimeInterval(-30),
            pvPowerW: 0, loadPowerW: 0, loadPercent: 0, outputVoltage: 230, outputHz: 50,
            batteryPercent: 100, batteryVoltage: 56.1, gridVoltage: 231, gridHz: 50, ratedPowerW: 6000,
            todayKWh: 0.0, plantName: "PLANT", machineType: "Off Grid Tie", collectorOnline: true),
        previous: EnergyFlows(solarW: 0, gridW: 0, batteryW: -400, loadW: 380))

    public static let offline = HeroScenario(
        id: "offline", title: "No data yet (first load or offline)", snapshot: nil,
        previous: .zero)

    public static let all: [HeroScenario] = [sunnyCharging, eveningBattery, nightGrid, outageLowBattery, standby, offline]
}
