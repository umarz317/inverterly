#!/usr/bin/env node
// Regenerates Tests/InverterCoreTests/SigningVectors.swift from the REAL Node client, so the Swift
// port is checked against what the Node project actually sends, byte for byte.
//
//   node Tools/make-signing-vectors.mjs [path/to/inverter-control/lib/shinemonitor.js] > Tests/InverterCoreTests/SigningVectors.swift
//
// Two kinds of vector come out:
//   1. hashes, logins, requests: lib/shinemonitor.js login() and request() on made-up inputs,
//      including user names that need URL-encoding.
//   2. flow: every URL the whole read path sends (fetchCloudPayload() in lib/cloud.js, the
//      fallback device list, and the day history as forecast-test/pull-history.mjs builds it).
//
// Nothing here touches the network or the account: fetch and Date.now are stubbed, every input
// is made up, and the Node project's .session.json is neither read nor written (loadSession and
// saveSession are disabled before the flow runs). Afterwards `python3 Tools/scan-secrets.py`
// confirms no real credential is in the output.
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";

const clientPath = process.argv[2] || join(homedir(), "Documents/inverter-control/lib/shinemonitor.js");
const { ShineMonitorClient, PROFILES } = await import(pathToFileURL(clientPath).href);

const sha1 = (text) => createHash("sha1").update(text, "utf8").digest("hex");
const sent = [];
globalThis.fetch = async (url) => {
  sent.push(String(url));
  return { json: async () => ({ err: 0, desc: "ERR_NONE", dat: { secret: "made-up-secret-0123456789abcdef", token: "made-up-token-fedcba9876543210", expire: 3600 } }) };
};

const hashes = ["", "abc", "made-up-password", "pässwörd ☀ 太阳能", "The quick brown fox jumps over the lazy dog"]
  .map((text) => ({ text, hex: sha1(text) }));

const logins = [];
for (const [profile, now, user, password] of [
  ["watchpower", 1700000000000, "plainuser", "made-up-password"],
  ["dessmonitor", 1760000000123, "solar user+tag@example.com", "pässwörd ☀ 太阳能"],
  ["solarpower", 1765432109876, "a&b=c/d?e#f%g'h(i)j*k!l~m", "x y"],
  ["dessmonitor", 1760000000999, "用户 ñ", "made-up-password"],
]) {
  Date.now = () => now;
  const client = new ShineMonitorClient(PROFILES[profile]);
  client.saveSession = () => {};
  sent.length = 0;
  await client.login(user, password);
  logins.push({ profile, salt: String(now), user, password, url: sent[0], expireAt: client.expireAt });
}

const requests = [];
for (const [profile, now, secret, token, action] of [
  ["dessmonitor", 1760000001000, "made-up-secret-0123456789abcdef", "made-up-token-fedcba9876543210", "webQueryDeviceEs"],
  ["dessmonitor", 1760000002000, "made-up-secret-0123456789abcdef", "made-up-token-fedcba9876543210", "queryDeviceLastData&pn=W0000000000001&devcode=2452&devaddr=1&sn=90000000000001&i18n=en_US"],
  ["watchpower", 1760000003000, "s3cr3t", "t0k3n", "queryDeviceDataOneDay&pn=W0000000000001&devcode=2452&devaddr=1&sn=90000000000001&date=2026-10-13&i18n=en_US"],
  ["dessmonitor", 1760000004000, "another-secret", "another-token", "queryPlants&page=0&pagesize=20&i18n=en_US"],
]) {
  Date.now = () => now;
  const client = new ShineMonitorClient(PROFILES[profile]);
  client.secret = secret;
  client.token = token;
  sent.length = 0;
  await client.request(action);
  requests.push({ profile, salt: String(now), secret, token, action, url: sent[0] });
}

// ---- The whole read flow, as the Node dashboard puts it on the wire ----
//
// The vectors above prove the two signing functions. This part proves the rest: which actions are
// sent, with which parameters, in which order. It runs the real fetchCloudPayload() from
// lib/cloud.js against a canned cloud and records every URL. The Swift test then runs
// InverterService against the same canned cloud at the same clock and must produce the same URLs.
//
// Safety: the made-up account is put in process.env first, so the loader never takes the real
// one from .env; loadSession and saveSession are disabled, so the real .session.json is neither
// read nor written; fetch is the stub, so nothing reaches the network.
const FLOW = {
  clockMs: Date.UTC(2026, 9, 13, 12, 25, 0),           // TestClock's default in the Swift tests
  user: "tester@example.com",                          // TestAccount.config in the Swift tests
  password: "made-up-password",
  secret: "secret-1",                                  // what the Swift FakeCloud hands out first
  token: "token-1",
  device: { pn: "W0000000000000", sn: "00000000000000", devcode: 2452, devaddr: 1, pid: 1 },   // Fixtures.devicesEs
  day: "2026-10-13",
};
// The app's allow-list (DessReadOnly.actions) plus the login. Anything else the dashboard sends
// is left out of the vectors: the app does not send it.
const APP_ACTIONS = new Set(["authSource", "webQueryDeviceEs", "queryDevices", "queryDeviceLastData",
  "queryDeviceWarning", "queryPlants", "webQueryCollectorsEs", "queryDeviceDataOneDay"]);

Object.assign(process.env, {
  SHINEMONITOR_APP: "dessmonitor", SHINEMONITOR_USER: FLOW.user, SHINEMONITOR_PASSWORD: FLOW.password,
  SHINEMONITOR_PN: FLOW.device.pn, SHINEMONITOR_SN: FLOW.device.sn, SHINEMONITOR_BASE_URL: "", SHINEMONITOR_SOURCE: "",
});
ShineMonitorClient.prototype.loadSession = () => false;
ShineMonitorClient.prototype.saveSession = () => {};
Date.now = () => FLOW.clockMs;

const actionOf = (url) => (/[?&]action=([^&]*)/.exec(url) || [])[1] || "";
const canned = {
  authSource: { secret: FLOW.secret, token: FLOW.token, expire: 604800 },
  webQueryDeviceEs: { device: [FLOW.device] },
  queryDevices: { device: [FLOW.device] },
  queryPlants: { plant: [{ pid: 1, name: "PLANT", address: { timezone: 18000 } }] },
  queryDeviceLastData: [],
  queryDeviceWarning: { warning: [] },
  webQueryCollectorsEs: { collector: [] },
  queryDeviceDataOneDay: { title: [], row: [] },
};
const wire = [];
globalThis.fetch = async (url) => {
  const action = actionOf(String(url));
  wire.push({ action, url: String(url) });
  const dat = canned[action];
  return { json: async () => (dat === undefined ? { err: 1, desc: "ERR_FAIL" } : { err: 0, desc: "ERR_NONE", dat }) };
};

const { fetchCloudPayload } = await import(pathToFileURL(join(dirname(clientPath), "cloud.js")).href);
const payload = await fetchCloudPayload();
if (!payload.connected) throw new Error("the canned flow did not reach the reading");

// The two reads the app makes that the dashboard does not: the fallback device list (the client's
// own helper) and the day history, built exactly as forecast-test/pull-history.mjs builds it.
const flowClient = new ShineMonitorClient(PROFILES.dessmonitor);
flowClient.secret = FLOW.secret;
flowClient.token = FLOW.token;
await flowClient.getDevicesFallback();
const historySource = readFileSync(join(dirname(clientPath), "../forecast-test/pull-history.mjs"), "utf8");
for (const line of [
  "const q = `pn=${dev.pn}&devcode=${dev.devcode}&devaddr=${dev.devaddr}&sn=${dev.sn}`;",
  "client.request(`queryDeviceDataOneDay&${q}&date=${day}&i18n=en_US`)",
]) {
  if (!historySource.includes(line)) throw new Error("pull-history.mjs no longer builds its query this way: " + line);
}
{
  const dev = FLOW.device;
  const day = FLOW.day;
  const q = `pn=${dev.pn}&devcode=${dev.devcode}&devaddr=${dev.devaddr}&sn=${dev.sn}`;
  await flowClient.request(`queryDeviceDataOneDay&${q}&date=${day}&i18n=en_US`);
}

const flow = [];
const leftOut = new Set();
for (const sent of wire) {
  if (!APP_ACTIONS.has(sent.action)) { leftOut.add(sent.action); continue; }
  if (sent.action !== "authSource" && !sent.url.includes(`&token=${FLOW.token}&`)) {
    throw new Error("a captured request was not signed with the made-up session; refusing to write it out");
  }
  if (!flow.some((f) => f.url === sent.url)) flow.push(sent);
}
console.error(`flow: ${flow.length} URLs kept; dashboard-only actions left out: ${[...leftOut].length}`);

const q = (text) => JSON.stringify(text); // valid Swift literal for these inputs (no control characters)
const out = [];
out.push("// GENERATED by Tools/make-signing-vectors.mjs. Do not edit by hand.");
out.push("// Expected values come from running the real Node client (lib/shinemonitor.js) with fetch and");
out.push("// Date.now stubbed. Every input is made up; no account data is involved.");
out.push("");
out.push("enum SigningVectors {");
out.push("    struct Hash { let text: String; let hex: String }");
out.push("    struct Login { let profile: String; let salt: String; let user: String; let password: String; let url: String; let expireAt: Double }");
out.push("    struct Request { let profile: String; let salt: String; let secret: String; let token: String; let action: String; let url: String }");
out.push("");
out.push("    /// What the stubbed login answered with: `expire` seconds, so expireAt = salt + 3 600 000 ms.");
out.push("    static let loginLifetimeSeconds: Double = 3600");
out.push("");
out.push("    static let hashes: [Hash] = [");
for (const h of hashes) out.push(`        Hash(text: ${q(h.text)}, hex: ${q(h.hex)}),`);
out.push("    ]");
out.push("");
out.push("    static let logins: [Login] = [");
for (const l of logins) {
  out.push(`        Login(profile: ${q(l.profile)}, salt: ${q(l.salt)}, user: ${q(l.user)}, password: ${q(l.password)},`);
  out.push(`              url: ${q(l.url)},`);
  out.push(`              expireAt: ${l.expireAt}),`);
}
out.push("    ]");
out.push("");
out.push("    static let requests: [Request] = [");
for (const r of requests) {
  out.push(`        Request(profile: ${q(r.profile)}, salt: ${q(r.salt)}, secret: ${q(r.secret)}, token: ${q(r.token)},`);
  out.push(`                action: ${q(r.action)},`);
  out.push(`                url: ${q(r.url)}),`);
}
out.push("    ]");
out.push("");
out.push("    /// Every URL the Node dashboard's read flow (`fetchCloudPayload()` in lib/cloud.js) sent to a");
out.push("    /// canned cloud at a fixed clock, plus the fallback device list and the day history. Limited");
out.push("    /// to the actions the app is allowed to send.");
out.push("    struct Wire { let action: String; let url: String }");
out.push(`    static let flowClockMs: Double = ${FLOW.clockMs}`);
out.push(`    static let flowUser = ${q(FLOW.user)}`);
out.push(`    static let flowPassword = ${q(FLOW.password)}`);
out.push(`    static let flowDay = ${q(FLOW.day)}`);
out.push("    static let flow: [Wire] = [");
for (const f of flow) {
  out.push(`        Wire(action: ${q(f.action)},`);
  out.push(`             url: ${q(f.url)}),`);
}
out.push("    ]");
out.push("}");
console.log(out.join("\n"));
