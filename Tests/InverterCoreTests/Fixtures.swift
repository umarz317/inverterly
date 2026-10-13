// Payloads captured from the live DessMonitor API on 13 Oct 2026 (the `dat` part of each answer),
// then sanitised: the inverter serial is "00000000000000", the Wi-Fi stick PN is "W0000000000000",
// row ids, user ids and aliases are placeholders, and the plant's location is removed.
// There is no token, secret or account name in this file.

import Foundation
@testable import InverterCore

enum Fixtures {
    /// `queryDeviceLastData`, the logger report of 17:22:30. All 45 rows, in the order the API sent them.
    static let lastData = #"""
[
  {"title":"id","val":"00000000000000000000000000000000"},
  {"title":"Timestamp","val":"2026-10-13 17:22:30"},
  {"title":"SN","val":"00000000000000"},
  {"title":"Date Time","val":"2026-10-14 04:50:55"},
  {"title":"Machine type","val":"Off Grid Tie"},
  {"title":"Main CPU version","val":"07212"},
  {"title":"Slave 1 CPU version","val":"08607"},
  {"title":"AC Output Rating Voltage","unit":"V","val":"230.0"},
  {"title":"Grid Rating Current","unit":"A","val":"26.0"},
  {"title":"AC Output Rating Voltage","unit":"V","val":"230.0"},
  {"title":"AC Output Rating Current","unit":"A","val":"26.0"},
  {"title":"AC rated frequency","unit":"Hz","val":"50.0"},
  {"title":"AC output rating active power","unit":"W","val":"6000"},
  {"title":"AC output rating apparent power","unit":"VA","val":"6000"},
  {"title":"Battery Rating Voltage","unit":"V","val":"48.0"},
  {"title":"Battery recharge voltage","unit":"V","val":"47.2"},
  {"title":"Back To Discharge Voltage","unit":"V","val":"0.0"},
  {"title":"Battery under voltage","unit":"V","val":"47.2"},
  {"title":"Battery bulk voltage","unit":"V","val":"56.1"},
  {"title":"Battery float voltage","unit":"V","val":"56.1"},
  {"title":"Grid voltage","unit":"V","val":"233.3"},
  {"title":"Grid frequency","unit":"Hz","val":"49.8"},
  {"title":"PV1 Input voltage","unit":"V","val":"119.8"},
  {"title":"PV1 Input Power","unit":"W","val":"19"},
  {"title":"PV2 Input Power","unit":"W","val":"0"},
  {"title":"Battery Voltage","unit":"V","val":"52.7"},
  {"title":"Battery Capacity","unit":"%","val":"86"},
  {"title":"Battery Discharging Current","unit":"A","val":"21"},
  {"title":"Battery Charging Current","unit":"A","val":"0"},
  {"title":"AC output voltage","unit":"V","val":"230.0"},
  {"title":"AC Output Frequency","unit":"Hz","val":"49.8"},
  {"title":"Second AC output voltage","unit":"V","val":"230.0"},
  {"title":"Second AC output frequency","unit":"Hz","val":"49.8"},
  {"title":"Output load percent","unit":"%","val":"24"},
  {"title":"AC output active power","unit":"W","val":"1154"},
  {"title":"AC output apparent power","unit":"VA","val":"1495"},
  {"title":"Low DC cut off voltage on second output","unit":"V","val":"48.0"},
  {"title":"Setting discharge time on the 2nd output","val":"990M"},
  {"title":"Scheduled time for 2nd AC output on","val":"00:00"},
  {"title":"Scheduled time for 2nd AC output off","val":"00:00"},
  {"title":"Whether the second route is enabled","val":"The second route opens"},
  {"title":"Today generation","unit":"Wh","val":"22985"},
  {"title":"Month generation","unit":"Wh","val":"322639"},
  {"title":"Year generation","unit":"Wh","val":"5408657"},
  {"title":"Total generation","unit":"kWh","val":"9984.879"}
]
"""#

    /// `queryDeviceWarning`, first three of 17. All cleared (`status: false`).
    static let warnings = #"""
{
 "total": 3,
 "page": 0,
 "pagesize": 50,
 "warning": [
  {
   "id": "warning-1",
   "uid": 1,
   "did": 1,
   "pid": 1,
   "pn": "W0000000000000",
   "devcode": 2452,
   "devaddr": 1,
   "sn": "00000000000000",
   "status": false,
   "level": 0,
   "code": "0x00000001",
   "desc": "Line fail",
   "title": "Line fail",
   "handle": true,
   "remind": false,
   "gts": "2026-10-13 06:53:26",
   "cts": "2026-10-13 06:58:20"
  },
  {
   "id": "warning-2",
   "uid": 1,
   "did": 1,
   "pid": 1,
   "pn": "W0000000000000",
   "devcode": 2452,
   "devaddr": 1,
   "sn": "00000000000000",
   "status": false,
   "level": 0,
   "code": "0x00000001",
   "desc": "Line fail",
   "title": "Line fail",
   "handle": true,
   "remind": false,
   "gts": "2026-10-12 18:17:03",
   "cts": "2026-10-12 19:05:18"
  },
  {
   "id": "warning-3",
   "uid": 1,
   "did": 1,
   "pid": 1,
   "pn": "W0000000000000",
   "devcode": 2452,
   "devaddr": 1,
   "sn": "00000000000000",
   "status": false,
   "level": 0,
   "code": "0x00000001",
   "desc": "Line fail",
   "title": "Line fail",
   "handle": true,
   "remind": false,
   "gts": "2026-10-12 13:43:25",
   "cts": "2026-10-12 14:45:27"
  }
 ]
}
"""#

    /// `queryPlants`. The plant really is named "PLANT".
    static let plants = #"""
{
 "total": 1,
 "page": 0,
 "pagesize": 20,
 "plant": [
  {
   "pid": 1,
   "uid": 1,
   "name": "PLANT",
   "status": 1,
   "address": {
    "timezone": 18000
   },
   "nominalPower": "0.0000",
   "install": "2025-06-21 14:47:56",
   "gts": "2025-06-21 14:47:56"
  }
 ]
}
"""#

    /// `webQueryCollectorsEs`. Status 0 while the logger was reporting.
    static let collectors = #"""
{
 "total": 1,
 "page": 0,
 "pagesize": 50,
 "collector": [
  {
   "alias": "Logger",
   "pn": "W0000000000000",
   "descx": "Wi-Fi Kit RTU",
   "status": 0,
   "fireware": "3.6.8.6",
   "pid": 1,
   "pname": "PLANT",
   "signal": "100",
   "load": 1,
   "timeZone": 18000
  }
 ]
}
"""#

    /// `webQueryDeviceEs`, the device list the service asks for first.
    static let devicesEs = #"""
{
 "total": 1,
 "page": 0,
 "pagesize": 1,
 "device": [
  {
   "devalias": "Inverter",
   "sn": "00000000000000",
   "status": 0,
   "brand": 0,
   "devtype": "",
   "collalias": "Logger",
   "pn": "W0000000000000",
   "devaddr": 1,
   "devcode": 2452,
   "pid": 1,
   "outpower": "0.4740",
   "energyToday": "24.6480",
   "energyYear": "6489.3550",
   "energyTotal": "9984.5630",
   "soc": "0",
   "wifiStatus": 1
  }
 ]
}
"""#

    /// `queryDevices`, the fallback device list.
    static let devices = #"""
{
 "total": 1,
 "page": 0,
 "pagesize": 50,
 "device": [
  {
   "pn": "W0000000000000",
   "devcode": 2452,
   "devaddr": 1,
   "sn": "00000000000000",
   "alias": "Inverter",
   "timezone": 18000,
   "status": 0,
   "uid": 1,
   "pid": 1
  }
 ]
}
"""#

    /// `queryDeviceDataOneDay` for 2026-10-13, trimmed from 211 reports to 9 (the first two, six through the day, the last two).
    static let dayCurve = #"""
{"title": [
  {"title":"id","isDisplay":1},
  {"title":"Timestamp","isDisplay":1},
  {"title":"SN","isDisplay":1},
  {"title":"Date Time","isDisplay":1},
  {"title":"Machine type","isDisplay":1},
  {"title":"Main CPU version","isDisplay":1},
  {"title":"Slave 1 CPU version","isDisplay":1},
  {"title":"Grid Rating Current","unit":"A","isDisplay":1},
  {"title":"AC Output Rating Voltage","unit":"V","isDisplay":1},
  {"title":"AC Output Rating Voltage","unit":"V","isDisplay":1},
  {"title":"AC Output Rating Current","unit":"A","isDisplay":1},
  {"title":"AC rated frequency","unit":"Hz","isDisplay":1},
  {"title":"AC output rating active power","unit":"W","isDisplay":1},
  {"title":"AC output rating apparent power","unit":"VA","isDisplay":1},
  {"title":"Battery Rating Voltage","unit":"V","isDisplay":1},
  {"title":"Battery recharge voltage","unit":"V","isDisplay":1},
  {"title":"Back To Discharge Voltage","unit":"V","isDisplay":1},
  {"title":"Battery under voltage","unit":"V","isDisplay":1},
  {"title":"Battery bulk voltage","unit":"V","isDisplay":1},
  {"title":"Battery float voltage","unit":"V","isDisplay":1},
  {"title":"Grid voltage","unit":"V","isDisplay":1},
  {"title":"Grid frequency","unit":"Hz","isDisplay":1},
  {"title":"PV1 Input voltage","unit":"V","isDisplay":1},
  {"title":"PV1 Input Power","unit":"W","isDisplay":1},
  {"title":"PV2 Input Power","unit":"W","isDisplay":1},
  {"title":"Battery Voltage","unit":"V","isDisplay":1},
  {"title":"Battery Capacity","unit":"%","isDisplay":1},
  {"title":"Battery Discharging Current","unit":"A","isDisplay":1},
  {"title":"Battery Charging Current","unit":"A","isDisplay":1},
  {"title":"AC output voltage","unit":"V","isDisplay":1},
  {"title":"AC Output Frequency","unit":"Hz","isDisplay":1},
  {"title":"Second AC output voltage","unit":"V","isDisplay":1},
  {"title":"Second AC output frequency","unit":"Hz","isDisplay":1},
  {"title":"Output load percent","unit":"%","isDisplay":1},
  {"title":"AC output active power","unit":"W","isDisplay":1},
  {"title":"AC output apparent power","unit":"VA","isDisplay":1},
  {"title":"Low DC cut off voltage on second output","unit":"V","isDisplay":1},
  {"title":"Setting discharge time on the 2nd output","isDisplay":1},
  {"title":"Scheduled time for 2nd AC output on","isDisplay":1},
  {"title":"Scheduled time for 2nd AC output off","isDisplay":1},
  {"title":"Whether the second route is enabled","isDisplay":1},
  {"title":"Today generation","unit":"Wh","isDisplay":1},
  {"title":"Month generation","unit":"Wh","isDisplay":1},
  {"title":"Year generation","unit":"Wh","isDisplay":1},
  {"title":"Total generation","unit":"kWh","isDisplay":1}
],
"row": [
  {"realtime":true,"field":["00000000000000000000000000000000","2026-10-13 00:02:31","00000000000000","2026-10-13 11:30:52","Off Grid Tie","07212","08607","26.0","230.0","230.0","26.0","50.0","6000","6000","48.0","47.2","0.0","47.2","56.1","56.1","237.7","50.0","0.0","0","0","52.6","44","1","0","229.9","50.0","0.0","0.0","0","13","22","48.0","990M","00:00","00:00","The second route is not open","6721","297675","5383693","9959.915"]},
  {"realtime":true,"field":["00000000000000000000000000000000","2026-10-13 00:07:23","00000000000000","2026-10-13 11:35:46","Off Grid Tie","07212","08607","26.0","230.0","230.0","26.0","50.0","6000","6000","48.0","47.2","0.0","47.2","56.1","56.1","239.0","50.1","0.0","0","0","52.6","43","0","0","229.8","50.2","0.0","0.0","0","11","22","48.0","990M","00:00","00:00","The second route is not open","6721","297675","5383693","9959.915"]},
  {"realtime":true,"field":["00000000000000000000000000000000","2026-10-13 06:09:15","00000000000000","2026-10-13 17:37:44","Off Grid Tie","07212","08607","26.0","230.0","230.0","26.0","50.0","6000","6000","48.0","47.2","0.0","47.2","56.1","56.1","237.5","49.7","119.9","24","0","52.5","40","0","0","230.2","49.7","0.0","0.0","0","15","23","48.0","990M","00:00","00:00","The second route is not open","6724","297677","5383695","9959.917"]},
  {"realtime":true,"field":["00000000000000000000000000000000","2026-10-13 08:11:45","00000000000000","2026-10-13 19:40:14","Off Grid Tie","07212","08607","26.0","230.0","230.0","26.0","50.0","6000","6000","48.0","47.2","0.0","47.2","56.1","56.1","236.1","49.5","265.2","1548","0","53.5","46","0","26","230.3","49.5","0.0","0.0","0","14","23","48.0","990M","00:00","00:00","The second route is not open","7894","298848","5384865","9961.087"]},
  {"realtime":true,"field":["00000000000000000000000000000000","2026-10-13 10:16:11","00000000000000","2026-10-13 21:44:38","Off Grid Tie","07212","08607","26.0","230.0","230.0","26.0","50.0","6000","6000","48.0","47.2","0.0","47.2","56.1","56.1","240.2","49.8","244.0","3796","0","54.3","64","0","50","229.9","49.8","229.9","49.8","15","895","943","48.0","990M","00:00","00:00","The second route opens","13770","304722","5390739","9966.959"]},
  {"realtime":true,"field":["00000000000000000000000000000000","2026-10-13 12:25:03","00000000000000","2026-10-13 23:53:36","Off Grid Tie","07212","08607","26.0","230.0","230.0","26.0","50.0","6000","6000","48.0","47.2","0.0","47.2","56.1","56.1","241.4","49.8","251.9","4080","0","54.1","88","0","19","229.9","49.6","229.9","49.6","48","2778","2919","48.0","990M","00:00","00:00","The second route opens","22539","313491","5399508","9975.727"]},
  {"realtime":true,"field":["00000000000000000000000000000000","2026-10-13 14:27:21","00000000000000","2026-10-14 01:55:45","Off Grid Tie","07212","08607","26.0","230.0","230.0","26.0","50.0","6000","6000","48.0","47.2","0.0","47.2","56.1","56.1","240.6","49.9","239.6","2280","0","53.2","96","4","0","230.1","49.9","230.1","49.9","43","2423","2600","48.0","990M","00:00","00:00","The second route opens","22985","319714","5405732","9981.952"]},
  {"realtime":true,"field":["00000000000000000000000000000000","2026-10-13 17:17:34","00000000000000","2026-10-14 04:46:21","Off Grid Tie","07212","08607","26.0","230.0","230.0","26.0","50.0","6000","6000","48.0","47.2","0.0","47.2","56.1","56.1","233.7","49.9","119.9","35","0","52.8","86","22","0","229.9","49.9","229.9","49.9","22","1139","1379","48.0","990M","00:00","00:00","The second route opens","22985","322637","5408655","9984.877"]},
  {"realtime":true,"field":["00000000000000000000000000000000","2026-10-13 17:22:30","00000000000000","2026-10-14 04:50:55","Off Grid Tie","07212","08607","26.0","230.0","230.0","26.0","50.0","6000","6000","48.0","47.2","0.0","47.2","56.1","56.1","233.3","49.8","119.8","19","0","52.7","86","21","0","230.0","49.8","230.0","49.8","24","1154","1495","48.0","990M","00:00","00:00","The second route opens","22985","322639","5408657","9984.879"]}
]}
"""#

    static func json(_ text: String) -> JSONValue {
        // The fixtures are literals in this file; a parse failure is a broken test file.
        try! JSONValue.parse(text)
    }

    /// The API's envelope around a payload.
    static func envelope(_ dat: String) -> Data {
        Data(#"{"err":0,"desc":"ERR_NONE","dat":\#(dat)}"#.utf8)
    }

    static func failure(_ code: Int, _ desc: String) -> Data {
        Data(#"{"err":\#(code),"desc":"\#(desc)"}"#.utf8)
    }
}
