#!/usr/bin/env python3
"""Live parity check: the Swift port against the Node client, on the same logger report.

Runs InverterProbe (Swift) and Tools/node-reading.mjs (the Node dashboard's own code) one after
the other against the real cloud and compares every value they both report. Both sides only
read; see the header of each for what they refuse to send.

The logger reports about every 5 minutes. If a new report lands between the two runs the
timestamps differ and the pair is taken again, up to three times.

    python3 Tools/compare-live.py [path/to/inverter-control]

Prints readings only: no password, token, serial number or stick PN. Exit 0 = all equal.
"""
import os, subprocess, sys, time

PACKAGE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# The Node client rounds Wh to 0.01 kWh (22985 Wh -> 22.99); the Swift port keeps 22.985.
ROUNDED_BY_NODE = {"today_kwh", "month_kwh", "year_kwh", "total_kwh"}


def pairs(text, indented):
    out = {}
    for line in text.splitlines():
        if indented and not line.startswith("  "):
            continue
        line = line.strip()
        if "=" in line and " " not in line.split("=", 1)[0]:
            key, value = line.split("=", 1)
            out[key] = value
    return out


def run(command):
    done = subprocess.run(command, cwd=PACKAGE, capture_output=True, text=True)
    if done.returncode != 0:
        sys.exit(f"{command[0]} failed: {(done.stderr or done.stdout).strip().splitlines()[-1][:200]}")
    return done.stdout


def number(text):
    try:
        return float(text)
    except (TypeError, ValueError):
        return None


def same(key, swift, node):
    if key == "active_warnings":
        return (number(swift) or 0) > 0, (number(node) or 0) > 0
    a, b = number(swift), number(node)
    if a is None or b is None:
        return swift, node
    if key in ROUNDED_BY_NODE and abs(a - b) <= 0.005 + 1e-9:
        return b, b
    return a, b


def main():
    node_root = sys.argv[1:2]
    subprocess.run(["swift", "build", "--product", "InverterProbe"], cwd=PACKAGE, capture_output=True)
    for attempt in range(3):
        swift_out = run(["swift", "run", "--skip-build", "InverterProbe"])
        node = pairs(run(["node", "Tools/node-reading.mjs", *node_root]), indented=False)
        swift = pairs(swift_out.split("node equivalents:", 1)[-1], indented=True)
        if swift.get("timestamp") == node.get("timestamp"):
            break
        print(f"a new logger report landed between the two runs ({swift.get('timestamp')} / {node.get('timestamp')}), taking the pair again")
        time.sleep(3)
    else:
        sys.exit("could not get both readings from the same logger report")

    width = max(len(k) for k in node)
    differ = 0
    print(f"{'value'.ljust(width)}  {'swift':>20}  {'node':>20}")
    for key in node:
        if key not in swift:
            print(f"{key.ljust(width)}  {'(not printed)':>20}  {node[key]:>20}  MISSING")
            differ += 1
            continue
        a, b = same(key, swift[key], node[key])
        verdict = "same" if a == b else "DIFFERENT"
        if a == b and swift[key] != node[key]:
            verdict = "same (Node rounds to 0.01)" if key in ROUNDED_BY_NODE else "same"
        differ += a != b
        print(f"{key.ljust(width)}  {swift[key]:>20}  {node[key]:>20}  {verdict}")
    print(f"\n{len(node) - differ} of {len(node)} values agree" + ("" if differ == 0 else f", {differ} DIFFER"))
    return 1 if differ else 0


if __name__ == "__main__":
    sys.exit(main())
