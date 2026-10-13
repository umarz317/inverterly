# The cloud API Inverterly reads

Voltronic-type inverters (sold as Axpert, MPP Solar, and under many other names) report through a Wi-Fi logger to a vendor cloud. The WatchPower, SolarPower and DessMonitor phone apps read that cloud, and so does Inverterly. This page describes the part of the API the app uses.

It is unofficial. Nothing here comes from the vendor: it was worked out from a working client and checked against live DessMonitor and WatchPower accounts on 13 October 2026. Both read successfully through the DessMonitor host. Use your own account, and expect the vendor to change things without notice.

Everything on this page reads. See the last section for what is left out and why.

## Routes at a glance

There is one URL per host. The "route" is the `action` parameter.

| Action | Reads or writes | Used by the app | Purpose |
|---|---|---|---|
| `authSource` | login | yes | Trade username and password for a secret and a token |
| `webQueryDeviceEs` | reads | yes | List devices, with an energy summary |
| `queryDevices` | reads | yes, as a fallback | List devices |
| `queryDeviceLastData` | reads | yes | Latest report |
| `queryDeviceDataOneDay` | reads | yes | Every report of one day |
| `queryDeviceWarning` | reads | yes | Warnings |
| `queryPlants` | reads | yes | Plant name and time zone |
| `webQueryCollectorsEs` | reads | yes | Wi-Fi logger status |
| `querySPDeviceLastData` | reads | no | Extra parameters, in a different shape |
| `webQueryDeviceEnergyFlowEs` | reads | no | The vendor's own flow summary |
| `queryDeviceCtrlField` | reads | no | List the inverter's settings and their allowed values |
| `queryDeviceCtrlValue` | reads | no | Current value of one setting |
| `ctrlDevice` | **writes** | **no** | Change one setting |

The first eight are described next. The rest are under "Other read routes" and "Settings routes" further down.

## Hosts

There are three profiles. Pick the one that matches the phone app you sign in to.

| Profile | Base URL | App id sent | App version sent |
|---|---|---|---|
| `dessmonitor` | `https://web.dessmonitor.com/public/` | `wifiapp.volfw.watchpower` | `1.4.6.1` |
| `watchpower` | `https://web.dessmonitor.com/public/` | `wifiapp.volfw.watchpower` | `1.0.6.3` |
| `solarpower` | `http://android.shinemonitor.com/public/` | `com.voltronicpower.solarpower` | `1.0.6.3` |

All three send the company key `bnrl_frRFjEz8Mkn`. That is the phone app's own key and is the same for every user. It is not an account secret.

SolarPower's host is plain http. The legacy WatchPower host, `http://android.shinemonitor.com/public/`, accepted login but returned no device for the tested account. Set `SHINEMONITOR_BASE_URL` to that address only for an account whose device still lives there.

## The shape of every call

Every call is a `GET` to the base URL with everything in the query string. Every answer is JSON in the same envelope:

```json
{ "err": 0, "desc": "ERR_NONE", "dat": { } }
```

`err` is `0` on success. Anything else is a failure, with a short code name in `desc`. The useful part is `dat`.

## Logging in

Login is the action `authSource`. It returns a `secret` and a `token` that sign every later call.

```
salt   = milliseconds since 1970, as a string
action = "&action=authSource&usr=" + USERNAME.replace(" ", "%20") + "&company-key=" + COMPANY_KEY + APP_SUFFIX
sign   = sha1( salt + sha1(PASSWORD) + action )

GET {base}?sign={sign}&salt={salt}{action with USERNAME url-encoded}
```

`APP_SUFFIX` identifies the phone app:

```
&source=1&_app_client_=android&_app_id_={app id}&_app_version_={app version}&lang=en_US
```

Two details are easy to get wrong:

- The signature uses the raw username with every space replaced by `%20`. The URL carries the fully URL-encoded username (JavaScript's `encodeURIComponent`). For an email address, `@` becomes `%40` in the URL but stays `@` in the signed text. Signing a literal space returns `ERR_PASSWORD_VERIF_FAIL` even with the correct password; this was verified against a live WatchPower account.
- `sha1` is lowercase hex of the UTF-8 bytes, and the password is hashed once on its own before it goes into the signature.

A worked example with made-up values, for checking an implementation:

| Input | Value |
|---|---|
| salt | `1700000000000` |
| username | `me@example.com` |
| password | `correct horse` |
| profile | `dessmonitor` |
| `sha1(password)` | `2f9e53523b62abc141a2b4d6019d23cba835dbd0` |
| login `sign` | `832395bce094bf03c6f743e3b44cfb97ea6ab8fb` |

The answer's `dat` holds, among other fields:

| Field | Meaning |
|---|---|
| `secret` | Signs later requests. Never sent again. |
| `token` | Sent with every later request. |
| `expire` | Lifetime in seconds. Seven days (604800) when missing. |

Logging in again while a session is still valid returned the same token in testing, so a second client on the same account did not log the first one out.

## Signing a request

```
salt   = milliseconds since 1970, as a string
action = action name plus its parameters, for example "queryPlants&page=0&pagesize=20&i18n=en_US"
sign   = sha1( salt + secret + token + "&action=" + action )

GET {base}?sign={sign}&salt={salt}&token={token}&action={action}
```

The action string is signed exactly as it is sent. The app suffix from login is not added here.

Worked example with made-up values:

| Input | Value |
|---|---|
| salt | `1700000000000` |
| secret | `0123456789abcdef` |
| token | `feedfacefeedface` |
| action | `queryPlants&page=0&pagesize=20&i18n=en_US` |
| `sign` | `cbf318592d267ff81894df2b0a15f381ee44b400` |

## Naming the device

Most actions need to know which inverter. A device is addressed by four values that the device list returns:

```
pn={logger PN}&devcode={device code}&devaddr={device address}&sn={inverter serial}
```

This page calls that string `{device}`.

## The actions

These seven are the only ones the app sends.

| Action | Parameters | What comes back |
|---|---|---|
| `webQueryDeviceEs` | none | The account's devices, with an energy summary |
| `queryDevices` | `page=0&pagesize=50&i18n=en_US` | A plainer device list, used if the first one fails |
| `queryDeviceLastData` | `{device}&i18n=en_US` | The latest report as rows of title, value and unit |
| `queryDeviceDataOneDay` | `{device}&date=YYYY-MM-DD&i18n=en_US` | Every report of that day |
| `queryDeviceWarning` | `{device}&i18n=en_US&page=0&pagesize=50` | Warnings, newest first |
| `queryPlants` | `page=0&pagesize=20&i18n=en_US` | The plant: its name and time zone |
| `webQueryCollectorsEs` | `page=0&pagesize=50` | The Wi-Fi logger: status, signal, firmware |

The samples below are the `dat` part of real answers with identifiers replaced.

### webQueryDeviceEs

```json
{
  "total": 1, "page": 0, "pagesize": 1,
  "device": [{
    "devalias": "Inverter", "sn": "00000000000000", "pn": "W0000000000000",
    "devcode": 2452, "devaddr": 1, "pid": 1, "status": 0,
    "outpower": "0.4740", "energyToday": "24.6480",
    "energyYear": "6489.3550", "energyTotal": "9984.5630"
  }]
}
```

Take `pn`, `sn`, `devcode` and `devaddr` from the device you want. The energy figures here are in kWh and are rounded differently from the report rows, so the app uses the rows.

### queryDeviceLastData

An array of rows. Each has a `title`, a `val` that is always a string, and sometimes a `unit`.

```json
[
  {"title": "Timestamp", "val": "2026-10-13 17:22:30"},
  {"title": "Grid voltage", "unit": "V", "val": "233.3"},
  {"title": "PV1 Input Power", "unit": "W", "val": "19"},
  {"title": "Battery Capacity", "unit": "%", "val": "86"},
  {"title": "Battery Discharging Current", "unit": "A", "val": "21"},
  {"title": "AC output active power", "unit": "W", "val": "1154"},
  {"title": "Today generation", "unit": "Wh", "val": "22985"},
  {"title": "Total generation", "unit": "kWh", "val": "9984.879"}
]
```

A 6 kW off-grid unit returned 45 rows. The next section says which ones matter.

### queryDeviceDataOneDay

The whole day in one answer: a list of column titles, then one row per report with the values in the same order.

```json
{
  "title": [
    {"title": "id", "isDisplay": 1},
    {"title": "Timestamp", "isDisplay": 1},
    {"title": "PV1 Input Power", "unit": "W", "isDisplay": 1}
  ],
  "row": [
    {"realtime": true, "field": ["0000", "2026-10-13 00:02:31", "0"]},
    {"realtime": true, "field": ["0000", "2026-10-13 00:07:23", "0"]}
  ]
}
```

The titles are the same as the rows of `queryDeviceLastData`. A full day was about 290 reports. The `page` and `pagesize` parameters are ignored. A day with nothing stored yet answers with error 12, `ERR_NO_RECORD`, which the app treats as an empty chart.

### queryDeviceWarning

```json
{
  "total": 17, "page": 0, "pagesize": 50,
  "warning": [{
    "code": "0x00000001", "title": "Line fail", "desc": "Line fail",
    "status": false, "level": 0, "handle": true,
    "gts": "2026-10-13 06:53:26", "cts": "2026-10-13 06:58:20"
  }]
}
```

`status` false means the warning has cleared. `gts` is when it started and `cts` when it cleared. The app shows the first warning whose `status` is not false. "Line fail" is the grid going down.

### queryPlants

```json
{
  "total": 1,
  "plant": [{
    "pid": 1, "name": "PLANT", "status": 1,
    "address": {"timezone": 18000},
    "install": "2025-06-21 14:47:56"
  }]
}
```

`address.timezone` is the plant's offset from UTC in seconds. It matters because report timestamps are in the plant's local time with no zone attached.

### webQueryCollectorsEs

```json
{
  "collector": [{
    "alias": "Logger", "pn": "W0000000000000", "descx": "Wi-Fi Kit RTU",
    "status": 0, "signal": "100", "fireware": "3.6.8.6", "timeZone": 18000
  }]
}
```

`status` is the logger's state:

| Code | Meaning |
|---|---|
| 0 | Online |
| 1 | Offline |
| 2 | Fault |
| 3 | Standby |
| 4 | Warning |
| 5 | Error |
| 6 | Protocol error |

The app reports "offline" only for 1.

## Reading the report rows

Rows are matched by title, ignoring case. These are the ones the app reads on this family of inverter:

| Row title | Unit | Becomes |
|---|---|---|
| `Timestamp` | plant local time | When the logger last reported |
| `PV1 Input Power`, `PV2 Input Power` | W | Solar power, added together |
| `PV1 Input voltage` | V | Solar voltage |
| `AC output active power` | W | Load |
| `AC output apparent power` | VA | Load, apparent |
| `Output load percent` | % | Load as a share of rated output |
| `AC output voltage`, `AC Output Frequency` | V, Hz | Output |
| `Battery Capacity` | % | State of charge |
| `Battery Voltage` | V | Battery voltage |
| `Battery Charging Current` | A | Charge current |
| `Battery Discharging Current` | A | Discharge current |
| `Grid voltage`, `Grid frequency` | V, Hz | Grid |
| `AC output rating active power` | W | Rated output |
| `Today generation`, `Month generation`, `Year generation` | Wh | Energy, converted to kWh |
| `Total generation` | kWh | Lifetime energy |
| `Machine type` | text | Inverter type |

The traps, each of which produced a wrong number at some point:

- Rows with "rating" or "rated" in the title are nameplate values. `AC Output Rating Voltage` is not the live output voltage.
- Rows starting "Second AC output" describe the second output. Skip them when looking for the main one.
- "Battery Discharging Current" contains the words "charging current". Look for the charging row by its full name, or skip any title containing "discharg".
- `Timestamp` is the logger's report time. `Date Time` is the inverter's own clock and is often wrong.
- Energy rows mix units: three are in Wh and the total is in kWh. Read the `unit`.
- Every value is a string. An empty string means the value is missing, not zero.
- There is no row for the operating mode on this family, and none for grid power.

## What the app works out itself

Three things are not in the data and are derived:

| Value | How |
|---|---|
| Battery power | (charge current − discharge current) × battery voltage. Positive means charging. |
| Grid power | load + battery power − solar, when grid voltage is present and the battery is not discharging. Otherwise 0. Small results are treated as rounding, because battery current comes in whole amps. |
| Mode | Battery if it is discharging, grid if grid power is above zero, solar if the panels are producing, standby if nothing is drawing power. |

Grid power is an estimate. The app labels it that way.

## Errors

| Code | Name | What the app does |
|---|---|---|
| 0 | `ERR_NONE` | Success |
| 4 | `ERR_SIGN` | The secret no longer matches. Logs in again once and retries. |
| 10 | `ERR_NO_AUTH` | The token is no longer accepted. Logs in again once and retries. |
| 11 | `ERR_NO_PERMISSION` | Shown as an error. A new login cannot grant a permission. |
| 12 | `ERR_NO_RECORD` | Nothing stored for that query. Shown as empty, not as a failure. |

A wrong password is not retried at once. The wait doubles from one minute up to 32 minutes, so a typo in the account file does not hammer the vendor's login.

## Timing

- The logger reports about every five minutes. Asking more often returns the same report.
- The app asks once a minute while its panel is open and every two and a half minutes otherwise, and keeps a reading for 20 seconds so that several callers share one fetch.
- The server sometimes takes 10 to 40 seconds to answer, or drops a connection. The app waits 20 seconds per request. The warning, plant and logger lookups get 2.5 seconds after the reading arrives and are left out of that reading if they are late.

## Other read routes

These answered on the test account but the app does not use them.

| Action | Parameters | What it returned |
|---|---|---|
| `querySPDeviceLastData` | `{device}&i18n=en_US` | The report grouped under `pars`, each group a list of `{par, val, unit}`. Nothing the main report lacked. |
| `webQueryDeviceEnergyFlowEs` | `{device}` | A ready-made flow summary: `bt_status`, `pv_status`, `gd_status`, `bc_status`. It reported battery power as 0 while the battery was discharging 22 A, so the app works the flows out itself. |
| `queryDeviceEnergyMonthPerDay` | `{device}&date=YYYY-MM` | A `perday` list for the month. Every value was 0 on this account. |
| `queryPlantEnergyMonthPerDay` | `plantid={pid}&date=YYYY-MM` | The same, also all zeros. |
| `queryDeviceEnergyDay`, `queryPlantActiveOuputPowerOneDay` | a date | Error 12, `ERR_NO_RECORD`. |

A sample of the flow summary:

```json
{
  "bt_status": [{"par": "bt_battery_capacity", "val": "86.0000", "unit": "%", "status": 1},
                {"par": "battery_active_power", "val": "0", "status": 0}],
  "pv_status": [{"par": "pv_output_power", "val": "0.0350", "unit": "kW", "status": 1}],
  "gd_status": [{"par": "grid_active_power", "val": "0", "status": 2}],
  "bc_status": [{"par": "load_active_power", "val": "1.1390", "unit": "kW", "status": -1}]
}
```

## Settings routes

Inverterly does not send any of these. They are documented because people ask how the phone app changes a setting, and because anyone adding that to a fork should know exactly what is involved.

Two of the three only read. The third changes the inverter.

### queryDeviceCtrlField: list the settings

```
queryDeviceCtrlField&{device}&i18n=en_US&source=1
```

Returns every setting the inverter accepts, with its id, its name, a unit when it has one, and the allowed values when the choice is a fixed list.

```json
{
  "field": [
    {"id": "bse_output_source_priority", "name": "Output source priority",
     "item": [{"key": "0", "val": "Solar-Utility-Battery"}, {"key": "1", "val": "Solar-Battery-Utility"}]},
    {"id": "bat_charging_float_voltage", "name": "Battery float voltage", "unit": "V"}
  ]
}
```

A setting with an `item` list takes one of the listed `key` values. A setting without one takes a number or a time.

### queryDeviceCtrlValue: read one setting

```
queryDeviceCtrlValue&{device}&id={setting id}&i18n=en_US
```

```json
{"id": "gd_bse_input_voltage_read", "name": "AC Output Rating Voltage", "val": "230.0"}
```

The answer gives the display value (`230.0`), not the option key (`2300`).

### ctrlDevice: change one setting

```
ctrlDevice&{device}&id={setting id}&val={value}
```

`val` is the option's `key` for a list setting (for example `1`, not `Solar-Battery-Utility`), or the number for a free one. Both `id` and `val` are URL-encoded, and the request is signed like any other.

This route is written down from the Node client this project grew out of. Inverterly has never sent it, and its answer is not documented here because it was never captured.

### The settings on a 6 kW off-grid unit

The list differs between models. This is what one unit returned, to show the kind of thing that is there. Ask your own inverter with `queryDeviceCtrlField` before relying on any id.

| Setting id | Name | Allowed values |
|---|---|---|
| `bse_output_source_priority` | Output source priority | 0 Solar-Utility-Battery, 1 Solar-Battery-Utility |
| `bat_charging_source` | Charger source priority | 0 Solar first, 1 Solar and Utility, 2 Only solar |
| `cts_power_priority` | Solar supply priority | 0 Battery-Load-Utility, 1 Load-Battery-Utility |
| `bse_input_voltage_range` | Input voltage range | 0 APL, 1 UPS |
| `bat_battery_type` | Battery type | 0 AGM, 1 Flooded, 2 User, 3 Pylontech, 5 WECO, 6 Soltaro, 8 LIB, 9 LIC |
| `bat_max_charging_current` | Max charging current (A) | 010 to 140 in steps of 10 |
| `bat_ac_charging_current` | Max AC charging current (A) | 002, then 010 upward in steps of 10 |
| `bat_charging_bulk_voltage` | Battery bulk voltage (V) | a number |
| `bat_charging_float_voltage` | Battery float voltage (V) | a number |
| `bat_battery_cut_off_voltage` | Battery cut off voltage (V) | a number |
| `bat_battery_charging_voltage` | Back to grid voltage (V) | 440 to 510, meaning 44.0 to 51.0 |
| `bat_battery_dischargevoltage` | Back to discharge voltage (V) | 000 FULL, 480 to 580 |
| `gd_bse_input_voltage` | AC output rating voltage (V) | 2200, 2300, 2400 |
| `gd_bse_output_frequency` | AC output rating frequency (Hz) | 50, 60 |
| `std_power_for_grid_frequency_ctrl_i` | Solar feed to grid | 68 Disable, 69 Enable |
| `std_overload_bypass_ctrl_b` | Overload bypass | 68 Disable, 69 Enable |
| `std_overload_restart_ctrl_d` | Overload restart | 68 Disable, 69 Enable |
| `std_temperature_restart_ctrl_e` | Over temperature restart | 68 Disable, 69 Enable |
| `std_buzzer_ctrl_a` | Buzzer | 68 Disable, 69 Enable |
| `std_backlight_function_ctrl_f` | Backlight | 68 Disable, 69 Enable |
| `std_primary_source_alarm_ctrl_g` | Alarm when primary source is interrupted | 68 Disable, 69 Enable |
| `std_lcd_return_to_default_display_ctrl_c` | Display returns to default page | 68 Disable, 69 Enable |
| `std_fault_code_record_ctrl_h` | Fault code record | 68 Disable, 69 Enable |
| `std_battrey_auto_turnon_ctrl_k` | Lithium battery auto turn on | 68 Disable, 69 Enable |
| `std_battrey_immediately_turnon_ctrl_j` | Lithium battery immediate turn on | 68 Disable, 69 Enable |
| `cts_start_time_for_enable_ac_charger_working`, `cts_endin_time_for_enable_ac_charger_working` | AC charger working hours | a time |
| `cts_scheduled_time_for_ac_output_on`, `cts_scheduled_time_for_ac_output_off` | AC output hours | a time |
| `cts_set_date_time` | Set the inverter's clock | a date and time |
| `cts_regulations_state` | Country regulations | 0 India, 1 Germany, 2 South American |
| `cts_reset_pv_energy_storage` | Reset the PV energy counters | 1 Reset |
| `sys_set_default` | Restore factory defaults | 49 Restore |
| `sled_*` (seven ids) | The front RGB light: on or off, brightness, speed, effect, colours | fixed lists |

The Disable and Enable keys are 68 and 69 because they are the letters D and E.

### If you want settings control in the bar

It is possible, and it is a deliberate decision to leave it out. Before adding it to a fork:

- A wrong battery voltage or charging current can damage a battery. A wrong output voltage or frequency can damage what is plugged in. `sys_set_default` and `cts_reset_pv_energy_storage` cannot be undone from the app.
- The cloud passes the command to the logger, which reports back on its own schedule. A change can take minutes to show, and a failed one may look the same as a slow one.
- To send any of these three routes you have to add its name to `DessReadOnly.actions`. `ReadOnlyGuardTests` then fails on purpose. Changing that test is the moment to decide you mean it.

A sensible shape for it, if you build it: off unless the user turns it on, one setting at a time, the old and new value shown side by side with a confirmation, the value read back with `queryDeviceCtrlValue` afterwards, and the dangerous ids above left out of the list altogether.

## What is left out on purpose

The app sends none of the settings routes above, not even the two that only read. A wrong battery or output setting can damage equipment, so the code makes sending one hard to do by accident:

- `DessReadOnly.actions` is an allow-list of the seven actions above. Any other action is refused before it is signed.
- An action string may not carry its own `action`, `sign`, `salt` or `token` parameter, which is how a second action could otherwise ride along with a query.
- A test fails if a control action's name appears anywhere in `Sources`.

## Trying it

`docs/examples/read_inverter.py` is a 60-line client written from this page alone, using only Python's standard library:

```bash
SHINEMONITOR_USER=you SHINEMONITOR_PASSWORD=secret python3 docs/examples/read_inverter.py
```

The Swift equivalent prints one reading and the size of today's log:

```bash
swift run InverterProbe
```

## Not verified

- The `watchpower` and `solarpower` hosts. Only `dessmonitor` was tested live.
- A session expiring on its own after seven days. The re-login path was tested by tampering with a saved session.
- An active warning in live data. The account had only cleared warnings during testing.
