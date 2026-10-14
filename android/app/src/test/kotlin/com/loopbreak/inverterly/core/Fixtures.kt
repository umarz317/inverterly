package com.loopbreak.inverterly.core

/** A payload captured from the live DessMonitor API on 13 Oct 2026 and sanitised (no serial, account or token in it). */
object Fixtures {
    /** `queryDeviceLastData`, the logger report of 17:22:30. All 45 rows, in the order the API sent them. */
    val lastData = """
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
"""

    val devicesEs = """
[{"pn":"W0000000000000","sn":"00000000000000","devcode":2452,"devaddr":1,"alias":"","pid":1,"timezone":18000}]
"""
}
