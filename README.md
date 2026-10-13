# InverterBar

A macOS menu bar app that shows a Voltronic-type solar inverter live: what the panels are making, what the house is drawing, where the battery stands, and whether the grid is up.

These inverters are sold as Axpert, MPP Solar and under many other names. They all report to the vendor cloud read by the WatchPower, SolarPower and DessMonitor phone apps, and InverterBar reads that cloud with the account you already have.

The menu bar item is a level bar with a rising sun while the panels produce and a crescent moon when they don't, with the battery percent beside it (or load, or solar). Click it for an animated picture of the energy flow, the load, tiles for solar, battery, grid and output, a chart of today, and a details list.

It only reads. No code path in the app can change an inverter setting. This is an unofficial project, not affiliated with Voltronic, DessMonitor, ShineMonitor or any inverter brand.

## Requirements

- macOS 14 or later, and Xcode's command line tools to build it.
- An inverter with a Wi-Fi logger that already reports to DessMonitor, WatchPower or SolarPower.
- The login you use in that phone app.

## Install

```bash
./Scripts/build-app.sh install
```

This builds a release binary, wraps it as `InverterBar.app`, copies it to `~/Applications` and opens it. Without `install` it only builds into `dist/`. The app is signed ad hoc, which is enough to run on the Mac that built it.

### Release DMG

```bash
./Scripts/make-dmg.sh
```

This builds `dist/InverterBar-<version>.dmg` with the app signed by your Developer ID Application identity (the first one in your keychain, or `INVERTERBAR_CODESIGN_IDENTITY`) using the hardened runtime, and signs the DMG too. To notarize and staple it, store notarytool credentials once with `xcrun notarytool store-credentials <name>` and run with `INVERTERBAR_NOTARY_PROFILE=<name>`. Without notarization, other Macs show a Gatekeeper warning on first open.

## Sign in

Click the menu bar item and enter your phone-app username and password. InverterBar works out which of the three apps the account belongs to and starts reading.

To switch accounts, open the three-dot menu and choose **Sign out**.

The account is saved to `~/.config/inverterbar/.env`, readable only by you. The login session is kept in `~/Library/Application Support/InverterBar/session.json`, also private. The password never appears in an error message or a log.

### Configure by hand

You can write the file yourself instead:

```bash
mkdir -p ~/.config/inverterbar
cp .env.example ~/.config/inverterbar/.env
chmod 600 ~/.config/inverterbar/.env
```

```
SHINEMONITOR_USER=your-login
SHINEMONITOR_PASSWORD=your-password
SHINEMONITOR_APP=dessmonitor
```

- `SHINEMONITOR_APP` is `dessmonitor`, `watchpower` or `solarpower`. WatchPower and DessMonitor use the DessMonitor server over https and have been checked with live accounts. SolarPower uses plain http and has not been tested.
- `SHINEMONITOR_BASE_URL=http://android.shinemonitor.com/public/` selects the legacy server for an older WatchPower account.
- `SHINEMONITOR_PN` and `SHINEMONITOR_SN` choose the starting device when the account has more than one; the Inverter menu overrides them.

The app looks for the file in this order:

1. the path in the `INVERTERBAR_ENV` environment variable
2. the path saved with `defaults write com.loopbreak.inverterbar envPath "/path/to/.env"`
3. `~/.config/inverterbar/.env`
4. `~/Documents/inverter-control/.env`, if the file above does not exist

If the file is in Documents, Desktop or Downloads, macOS asks once whether InverterBar may read that folder. If you say no, the panel reports that it cannot find the file; change the answer in System Settings under Privacy & Security, Files and Folders.

## History

Open **History** in the panel for how much solar you made, how much came from the grid and how much you used (the load), in kWh. **Days** lists each day of this month with a month total; **Months** adds up every month the cloud still has.

Each day is added up from the logger's 5-minute readings, which matches the cloud's own daily solar figure to within about 1%. Grid is estimated, as in the details list. A finished day is read once and kept in `~/Library/Application Support/InverterBar/history.json`; only today is read again. Sign out deletes it.

## Options

The three-dot menu has:

- **Illustration**: the animated picture in the panel. Inverter, Flow map or House.
- **Menu bar shows**: battery percent, load, solar, or the icon alone.
- **Animate menu bar icon**: the icon moves briefly when a new reading arrives. Turn it off for a still icon.
- **Inverter**: when the account has more than one, which inverter the panel and menu bar show. Each keeps its own history.
- **Open at login**
- **Sign out**

## How fresh the numbers are

The logger reports to the cloud about every five minutes, so that is the real resolution. The app asks once a minute while the panel is open and every two and a half minutes otherwise.

The header shows when the logger last reported, and a banner appears after fifteen quiet minutes. If the logger has been quiet that long, or nothing could be fetched for ten minutes, the menu bar item drops its number and dims, so an old percentage never looks current.

The vendor's server can take ten seconds or more to answer, so the first reading after launch may be slow.

Grid power is not in the vendor's data for this kind of inverter. The app estimates it as load plus battery charging, minus solar and battery discharge, and labels it as estimated in the details list.

Left running, it uses about 0.17% of one CPU core and 17 MB of memory with the panel closed (measured on an M1 Pro), and about 3% of a core while the panel is open and animating.

## Run from source

```bash
swift run InverterBar
```

Print one live reading in the terminal:

```bash
swift run InverterProbe
```

## Documentation

- [docs/API.md](docs/API.md): the cloud API: hosts, login and request signing with worked examples, each route the app uses, error codes, and the settings routes the app deliberately does not send.
- [docs/LIBRARY.md](docs/LIBRARY.md): using `InverterCore` from your own Swift code.
- [docs/examples/read_inverter.py](docs/examples/read_inverter.py): a 60-line read-only Python client.

## Code layout

- `Sources/InverterCore`: cloud client, request signing, parsing and the `EnergySnapshot` model. No UI.
- `Sources/InverterUI`: the status item and panel window, SwiftUI views, menu bar icon, and the illustrations in `Hero/`. Each illustration is one `Canvas` that is a pure function of the reading and the time.
- `Sources/InverterBar`: the app entry point.
- `Sources/InverterProbe`: prints one live reading.

Run the tests with `swift test`. Their fixtures are real answers from one inverter with serial numbers and ids replaced.

`Tools/scan-secrets.py` checks that none of your account's values (username, password, serials, session token) has ended up in the repository. Run it before pushing a fork.

## Licence

MIT. See `LICENSE`.
