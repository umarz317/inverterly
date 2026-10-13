# Inverterly for iPhone

The iPhone and iPad app for Inverterly. It reads the same Voltronic-type inverter cloud as the Mac menu bar app, with the same account, and shows it as a phone app: what the panels are making, what the house is drawing, where the battery stands, and today's and earlier days' energy.

<p align="center">
  <img src="../docs/ios/now.png" width="240" alt="The Now tab: live reading, energy flow and tiles (made-up readings)">
  <img src="../docs/ios/today.png" width="240" alt="The Today tab: energy mix, power chart and peaks (made-up readings)">
  <img src="../docs/ios/history.png" width="240" alt="The History tab: monthly mix, a bar per day and the list (made-up readings)">
</p>

Like the Mac app it only reads. No code path can change an inverter setting.

## What it shows

- **Now**: whether the house runs on solar, battery or grid, the animated energy flow, the load against the inverter's rating, and a tile each for solar, battery, grid and output. Details (voltages, currents, frequency, logger status) are underneath.
- **Today**: how much of today's energy came from the sun, with solar, grid and load totals; the day's power curve, which you can drag across to read any moment; the day's peaks; and the battery's charge through the day.
- **History**: Days for this month or Months going back, with the period's energy mix, a bar per day or month (drag to pick one), and the list.
- **Settings** (the gear): pick the inverter when the account has more than one, choose the illustration, and sign out.

The dot under each title is green while readings are fresh, orange once the logger has gone quiet, and grey before the first reading. Pull down on any tab to refresh. The app reads while it is in front and stops when it is not; it has no background refresh or widgets.

## Sign in

Use the username and password from your inverter's monitoring phone app. The app tries each of the three cloud identities in turn and keeps the one that works.

The password goes into the iOS Keychain. The username and app identity are saved in the app's own container (`Library/Application Support/Inverterly/.env`), and the login session next to it. With **Remember me** off, the account, session and saved history are removed the next time the app is launched, so it asks again.

## Requirements

- iOS or iPadOS 17 or later.
- Xcode 16 or later to build it.
- An Apple development team for signing. A free personal team works; its builds stop opening after seven days and have to be installed again.

## Build and run

Open `iOS/Inverterly.xcodeproj`, choose the **Inverterly iOS** scheme, set your team under Signing & Capabilities, and run it on a simulator or your device.

## Install on your iPhone for testing

### Once per Mac and iPhone

1. In Xcode, open Settings, Accounts, and add your Apple ID. A free Apple ID gives you a personal team; a paid developer account gives builds that last a year instead of seven days.
2. Connect the iPhone with a cable, unlock it and tap **Trust** when it asks about this computer.
3. On the iPhone, turn on **Settings, Privacy & Security, Developer Mode**. The phone restarts; confirm when it comes back.
4. In Xcode, open `iOS/Inverterly.xcodeproj`, select the **Inverterly iOS** target, Signing & Capabilities, and pick your team. With a free personal team, also change the Bundle Identifier to something of your own, such as `com.yourname.inverterly`, because a bundle id can belong to only one team.

After the first install over a cable, Xcode can also install over Wi-Fi while the phone and Mac are on the same network.

### From Xcode

Choose your iPhone as the run destination at the top of the window and press Run (⌘R). Xcode builds, installs and opens the app.

With a free personal team, the first launch is refused until you trust yourself as the developer: on the iPhone open **Settings, General, VPN & Device Management**, tap your Apple ID under Developer App and choose **Trust**.

### From the command line

List the connected devices and note the iPhone's identifier:

```bash
xcrun devicectl list devices
```

Build a signed Release build for that iPhone, with your team id from Xcode's Accounts settings:

```bash
xcodebuild -project iOS/Inverterly.xcodeproj -scheme "Inverterly iOS" -configuration Release -destination 'id=<device-id>' -derivedDataPath build/ios -allowProvisioningUpdates DEVELOPMENT_TEAM=<your-team-id> build
```

Install it:

```bash
xcrun devicectl device install app --device <device-id> build/ios/Build/Products/Release-iphoneos/Inverterly.app
```

Open it:

```bash
xcrun devicectl device process launch --terminate-existing --device <device-id> com.loopbreak.inverterly
```

Use your own bundle id in the last command if you changed it.

### When it does not work

- **"Could not be unlocked" when launching**: the app is installed; unlock the phone and open it from the Home Screen.
- **"Operation timed out" while installing**: the Wi-Fi connection to the phone dropped. Run the install again, or use a cable.
- **"Untrusted Developer" on the phone**: trust your Apple ID under Settings, General, VPN & Device Management.
- **Signing fails with "No profiles" or a bundle id error**: check the team is set, keep `-allowProvisioningUpdates`, and with a free team use a bundle id of your own.
- **The app stops opening after a week**: builds from a free personal team expire after seven days. Install again.

## Demo mode

Debug builds take two launch arguments for working on the layout without an account (set them under Product, Scheme, Edit Scheme, Arguments):

- `-demo` shows made-up readings, a full day's curve and a month of history.
- `-slow` with `-demo` holds the first reading back for 20 seconds, to look at the loading screen.

Neither exists in Release builds.

## How it is built

The app target is a thin shell. Everything else comes from the Swift package at the repository root, which also builds the Mac app:

- `iOS/Inverterly/InverterlyApp.swift`: the entry point. It creates the `AppStore`, starts reading, and tells the store when the app comes to the front.
- `iOS/Inverterly/DemoProvider.swift`: the made-up readings behind `-demo` (Debug only).
- `iOS/Inverterly/Assets.xcassets`: the app icon and the logo on the sign-in screen.
- `Sources/InverterCore`: the cloud client, parsing and models, shared with the Mac app unchanged.
- `Sources/InverterUI/Phone`: the phone screens (`PhoneRootView`, Now, Today, History, sign-in, Settings), compiled only for iOS.
- `Sources/InverterUI`: the store, the hero illustrations, the battery ring, the load gauge and the details list, shared with the Mac panel.

The panel's type sizes are set for the Mac; on iOS `PanelScale` raises them to iOS sizes and follows the text size chosen in Settings. Colours are the iOS system palette, so they adapt to light and dark mode: solar is orange, the grid grey, the battery green, and orange is the app's tint.

Run the shared tests from the repository root with `swift test`.
