# Inverterly for Android

The Android app for Inverterly: the same Voltronic-type inverter cloud, the same account, the same Now, Today and History screens as the iOS app, written in Kotlin with Jetpack Compose. Like the other apps it only reads. No code path can change an inverter setting.

It is a native port of the Swift code, not a wrapper:

| iOS | Android |
|---|---|
| `Sources/InverterCore` | `app/src/main/kotlin/com/loopbreak/inverterly/core` (client, signing, parser, service, models) |
| `AppStore` | `AppStore.kt` (a `ViewModel` holding Compose state) |
| `Sources/InverterUI/Phone` | `ui/Screens.kt`, `ui/SignIn.kt`, `ui/Settings.kt`, `ui/Charts.kt` |
| `HeroFlow` | `ui/HeroFlow.kt` |
| Keychain | Android Keystore (AES-GCM) in `core/AccountStore.kt` |

What is not ported: the "Inverter" and "House" illustrations (the Flow map is the only hero), and the `.env` account file (the account is entered in the app).

## Requirements

- Android 8.0 (API 26) or later.
- JDK 17 and the Android SDK (platform 36). Android Studio has both.
- An inverter with a Wi-Fi logger that already reports to DessMonitor, WatchPower or SolarPower.

## Build and run

Open the `android` folder in Android Studio and run the **app** configuration, or from a terminal:

```bash
cd android
./gradlew :app:installDebug
```

Run the unit tests (signing vectors, parser, read-only guard):

```bash
./gradlew :app:testDebugUnitTest
```

A debug build can show made-up readings without an account:

```bash
adb shell am start -n com.loopbreak.inverterly/.MainActivity --ez demo true
```

## Sign in

Use the username and password from your inverter's monitoring phone app. The app tries each of the three cloud identities in turn and keeps the one that works. The password is encrypted with a key held in the Android Keystore; the username and identity sit in the app's private storage, which is excluded from Android backup. With **Remember me** off, the account, session and saved history are removed the next time the app is opened.

The SolarPower host is plain http (see [docs/API.md](../docs/API.md)), so the manifest allows cleartext traffic.

## Raw readings

Settings has a **Raw readings** row for troubleshooting. It asks the cloud for everything it reports for the selected inverter (the live rows, the vendor's flow summary, and the columns of today's history with their latest values) and shows it as text you can copy or share. The serial number and logger PN are replaced first. It is how to find out whether a model reports a figure the app does not use yet, such as grid or feed-in power on an inverter with reverse metering. It sends one more read-only query, `webQueryDeviceEnergyFlowEs`, which is on the allow-list.

## Grid export (reverse metering)

An inverter that reports itself as a "Grid Tie" can send surplus power to the grid, but the cloud has no export reading for it (its grid power is always 0). So the app estimates it: the power the panels make beyond the load and the battery's charging, less about 5% for conversion losses, and only with grid voltage present. A small surplus is treated as measurement error. Summed over the logger's 5-minute readings it gives kWh exported per day and month.

It shows as an "Exporting" Grid tile and a reversed grid flow on Now, an Export total on Today and History, and an Export column in the History list. Models that report "Off Grid Tie", or no type at all, never show export. It is an estimate: check it against your meter before relying on it for billing. The iOS app does not estimate export yet.
