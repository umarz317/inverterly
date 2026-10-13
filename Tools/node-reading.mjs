#!/usr/bin/env node
// Prints the Node dashboard's own reading (fetchCloudPayload() in lib/cloud.js) in the same
// key=value form as InverterProbe's "node .basic equivalents" block, for a side-by-side check.
//
//   node Tools/node-reading.mjs [path/to/inverter-control]
//
// It is stricter than the dashboard it borrows from:
//   - READ-ONLY, and then some: any action with "ctrl" in its name is refused here before it is
//     sent, including the dashboard's query of the control-field list. Nothing is written to the
//     inverter and its settings are not even listed.
//   - saveSession is disabled, so the Node project's .session.json is never written.
//   - The output holds readings only: no password, token, serial number or stick PN.
import { homedir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const root = process.argv[2] || join(homedir(), "Documents/inverter-control");
const shine = await import(pathToFileURL(join(root, "lib/shinemonitor.js")).href);
const proto = shine.ShineMonitorClient.prototype;
proto.saveSession = function () {};
const realRequest = proto.request;
let blocked = 0;
proto.request = function (action) {
  if (/ctrl/i.test(String(action))) {
    blocked++;
    return Promise.reject(new Error("blocked: this tool sends no control action"));
  }
  return realRequest.call(this, action);
};

const { fetchCloudPayload } = await import(pathToFileURL(join(root, "lib/cloud.js")).href);

let payload;
try {
  payload = await fetchCloudPayload();
} catch (error) {
  // The Node client puts nothing secret in its messages, but cut at "?" anyway in case a URL is ever added.
  console.error("node reading failed: " + String(error.message).split("?")[0].slice(0, 120));
  process.exit(1);
}
if (!payload.connected) {
  console.error("node reading failed: no inverter bound to the account");
  process.exit(1);
}

const b = payload.basic;
const show = (v) => (v == null ? "null" : String(v));
const row = (title) => (payload.lists.all.find((r) => String(r.title).toLowerCase() === title) || {}).val;
const out = {
  timestamp: row("timestamp"),
  grid_voltage_v: b.grid_voltage_v,
  grid_frequency_hz: b.grid_frequency_hz,
  ac_output_voltage_v: b.ac_output_voltage_v,
  ac_output_frequency_hz: b.ac_output_frequency_hz,
  ac_output_apparent_power_va: b.ac_output_apparent_power_va,
  ac_output_active_power_w: b.ac_output_active_power_w,
  output_load_percent: b.output_load_percent,
  battery_voltage_v: b.battery_voltage_v,
  battery_capacity_percent: b.battery_capacity_percent,
  battery_charging_current_a: b.battery_charging_current_a,
  battery_discharge_current_a: b.battery_discharge_current_a,
  pv1_input_voltage_v: b.pv1_input_voltage_v,
  pv1_plus_pv2_input_power_w: (b.pv1_input_power_w || 0) + (b.pv2_input_power_w || 0),
  today_kwh: payload.energy.day_energy_kwh,
  month_kwh: payload.energy.month_energy_kwh,
  year_kwh: payload.energy.year_energy_kwh,
  total_kwh: payload.energy.total_energy_kwh,
  rated_power_w: payload.rated.ac_output_active_power_rating_w,
  machine_type: payload.product.model_name,
  plant: payload.plant ? payload.plant.name : null,
  active_warnings: (payload.lists.warnings || []).filter((w) => w.val === "active").length,
};
for (const [key, value] of Object.entries(out)) console.log(`${key}=${show(value)}`);
console.error(`(control actions refused before sending: ${blocked})`);
