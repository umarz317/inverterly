# Using InverterCore in your own code

`InverterCore` is the part of the project with no interface: the cloud client, the parser and the data model. It is a normal SwiftPM library, so another app, a command line tool or a widget can read an inverter with it.

It needs macOS 14 or later and has no dependencies.

## Adding it

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/ahkamboh/inverterbar.git", branch: "main"),
],
targets: [
    .executableTarget(name: "MyTool", dependencies: [
        .product(name: "InverterCore", package: "inverterbar"),
    ]),
]
```

## One reading

```swift
import InverterCore

let service = InverterService()                 // finds the account file, see the README
let reading = try await service.fetchSnapshot()

print(reading.mode.label)                       // "On battery"
print(reading.loadPowerW)                       // 1154.0
print(reading.batteryPercent ?? 0)              // 86.0
print(reading.batteryPowerW)                    // -1106.7, negative while discharging
print(reading.gridPresent)                      // true
```

`InverterService` is an actor. It logs in when it needs to, remembers the session, finds the device once, and keeps a reading for 20 seconds so that several callers share one fetch. Pass `force: true` to skip that.

To give it the account directly, without an env file:

```swift
let config = InverterConfig(profile: .dessmonitor, user: "you@example.com", password: "…")
let service = InverterService(config: config)
```

## What a reading holds

`EnergySnapshot` is a plain value. Powers are in watts and energies in kWh. Anything the inverter did not report is `nil`.

| Property | Meaning |
|---|---|
| `fetchedAt` | When the app asked |
| `deviceTime` | When the logger last reported, about every five minutes |
| `pvPowerW`, `pvVoltage` | Solar input |
| `loadPowerW`, `loadApparentVA`, `loadPercent` | What the house is drawing |
| `outputVoltage`, `outputHz` | AC output |
| `batteryPercent`, `batteryVoltage` | Battery state |
| `batteryChargeA`, `batteryDischargeA` | Battery current, each zero or positive |
| `gridVoltage`, `gridHz` | Grid input |
| `ratedPowerW` | The inverter's rated output |
| `todayKWh`, `monthKWh`, `yearKWh`, `totalKWh` | Solar energy |
| `activeWarning` | Title of a warning that is active now |
| `plantName`, `machineType`, `collectorOnline` | Labels and logger state |

Worked out from those:

| Property | Meaning |
|---|---|
| `batteryPowerW` | Positive while charging, negative while discharging |
| `gridPresent` | Grid voltage above 90 V |
| `gridPowerW` | An estimate. The vendor does not report grid power. |
| `mode` | `.solar`, `.battery`, `.grid`, `.standby` or `.unknown` |
| `flows` | The four flows as one `EnergyFlows` value |
| `isStale(after:now:)` | True when the logger has been silent for 15 minutes |

## Today's log

```swift
let today = try await service.fetchToday()

for point in today.points {
    print(point.time, point.pvW, point.loadW, point.batteryPercent ?? 0)
}
print(today.peakPvW, today.peakLoadW)
```

`DayCurve` covers the plant's calendar day, midnight to midnight in the plant's own time zone, with one `DayCurvePoint` per logger report. It is empty just after midnight. It is kept for five minutes.

## When something goes wrong

Every error has readable text in `localizedDescription`, and none of them contains the password, the token or a URL.

| Type | Raised when |
|---|---|
| `InverterConfigError` | The account file is missing, unreadable, or lacks the username or password |
| `DessMonitorError` | The cloud refused the login or a request, the network failed, or it timed out |
| `InverterDataError` | The account has no inverter, or a report had no usable rows |

After a failure the last good values are still there:

```swift
let last = await service.lastSnapshot
```

## Swapping the data source

The interface only depends on a small protocol, which makes a fake source easy to write for previews and tests.

```swift
public protocol SnapshotProviding: Sendable {
    func fetchSnapshot(force: Bool) async throws -> EnergySnapshot
    func fetchToday() async throws -> DayCurve
}
```

`InverterService` conforms to it. `StaticSnapshotProvider(snapshot:curve:)` always returns the same reading.

## Talking to the cloud directly

`DessMonitorClient` is the layer under the service. It signs and sends one action and returns the `dat` part of the answer as a `JSONValue`.

```swift
let client = DessMonitorClient(config: config)
let plants = try await client.request("queryPlants&page=0&pagesize=20&i18n=en_US")
print(plants["plant"]?.arrayValue?.first?["name"]?.stringValue ?? "")
```

It only accepts the actions in `DessReadOnly.actions`. Anything else throws `DessMonitorError.actionNotAllowed` before a request is built. The routes and their answers are described in [API.md](API.md).

The signing functions are public too, in `DessSigning`, if you are writing a client in another language and want test vectors.
