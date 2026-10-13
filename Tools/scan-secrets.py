#!/usr/bin/env python3
"""Checks that no account secret has leaked into this workspace.

Reads the password (and its SHA-1, which is what the login signs with), the user name, the stick
PN and the inverter SN from the account .env, and the token and secret from every saved session
it can find, then searches every file under the given roots for them as raw bytes.

It never prints a value: only which KIND of secret was found, and in which file.

    python3 Tools/scan-secrets.py [file-or-folder ...]      (default: the package directory)

Exit status 0 = clean, 1 = something found, 2 = no secrets could be loaded to look for.
"""
import hashlib, json, os, sys

HOME = os.path.expanduser("~")
ENV = os.environ.get("INVERTERBAR_ENV") or next(
    (p for p in (os.path.join(HOME, ".config/inverterbar/.env"), os.path.join(HOME, "Documents/inverter-control/.env")) if os.path.exists(p)),
    os.path.join(HOME, ".config/inverterbar/.env"))
SESSIONS = [
    os.path.join(HOME, "Library/Application Support/InverterBar/session.json"),
    os.path.join(os.path.dirname(ENV), ".session.json"),
]
# Identifiers are not credentials, but the fixtures promise they were replaced.
ENV_KEYS = {"SHINEMONITOR_PASSWORD": "password", "SHINEMONITOR_USER": "username",
            "SHINEMONITOR_PN": "stick PN", "SHINEMONITOR_SN": "inverter SN"}
MIN_LENGTH = 6   # shorter values would match by accident


def env_values(path):
    out = {}
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return out
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        out.setdefault(key, value)
    return out


def files_under(root):
    if os.path.isfile(root):
        yield root
        return
    for folder, _, files in os.walk(root):
        for name in files:
            yield os.path.join(folder, name)


def main():
    roots = sys.argv[1:] or [os.path.dirname(os.path.dirname(os.path.abspath(__file__)))]
    needles = {}   # bytes -> kind

    env = env_values(ENV)
    for key, kind in ENV_KEYS.items():
        value = env.get(key, "")
        if len(value) >= MIN_LENGTH:
            needles[value.encode()] = kind
    if env.get("SHINEMONITOR_PASSWORD"):
        digest = hashlib.sha1(env["SHINEMONITOR_PASSWORD"].encode()).hexdigest()
        needles[digest.encode()] = "password SHA-1"

    for path in SESSIONS:
        try:
            session = json.load(open(path))
        except (OSError, ValueError):
            continue
        label = "app session" if "InverterBar" in path else "Node session"
        for field in ("token", "secret"):
            value = str(session.get(field) or "")
            if len(value) >= MIN_LENGTH:
                needles.setdefault(value.encode(), f"{label} {field}")

    kinds = sorted(set(needles.values()))
    if not any(k == "password" or k.endswith("token") or k.endswith("secret") for k in kinds):
        print("no password, token or secret could be loaded, so there is nothing to look for")
        return 2
    print("looking for: " + ", ".join(kinds))

    skip = {os.path.realpath(p) for p in SESSIONS} | {os.path.realpath(ENV)}
    scanned = 0
    hits = []
    for root in roots:
        for path in files_under(root):
            if os.path.islink(path) or os.path.realpath(path) in skip:
                continue
            try:
                data = open(path, "rb").read()
            except OSError:
                continue
            scanned += 1
            for needle, kind in needles.items():
                if needle in data:
                    hits.append((kind, path))
    print(f"scanned {scanned} files under {len(roots)} root(s)")
    for kind, path in sorted(set(hits)):
        print(f"FOUND {kind}: {path}")
    if not hits:
        print("clean: none of them appears anywhere")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
