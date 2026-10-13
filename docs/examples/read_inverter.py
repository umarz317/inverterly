#!/usr/bin/env python3
"""A minimal read-only client for the DessMonitor / ShineMonitor cloud, as documented in docs/API.md.

    SHINEMONITOR_USER=you SHINEMONITOR_PASSWORD=secret python3 docs/examples/read_inverter.py

Standard library only. It logs in, finds the first inverter on the account and prints its
latest reading. It sends query actions only; nothing here can change a setting.
"""
import hashlib, json, os, sys, time, urllib.parse, urllib.request

BASE = os.environ.get("SHINEMONITOR_BASE_URL", "https://web.dessmonitor.com/public/")
COMPANY_KEY = "bnrl_frRFjEz8Mkn"   # the vendor phone app's key, the same for every user
APP = "&source=1&_app_client_=android&_app_id_=wifiapp.volfw.watchpower&_app_version_=1.4.6.1&lang=en_US"


def sha1(text):
    return hashlib.sha1(text.encode("utf-8")).hexdigest()


def get(url):
    with urllib.request.urlopen(url, timeout=20) as response:
        answer = json.loads(response.read().decode("utf-8"))
    if answer.get("err") != 0:
        raise SystemExit(f"the cloud said: {answer.get('err')} {answer.get('desc')}")
    return answer.get("dat")


def login(user, password):
    salt = str(int(time.time() * 1000))
    # Escape spaces for signing; fully URL-encode the username when sending.
    signed_user = user.replace(" ", "%20")
    signed = f"&action=authSource&usr={signed_user}&company-key={COMPANY_KEY}{APP}"
    sent = f"&action=authSource&usr={urllib.parse.quote(user, safe='-_.!~*' + chr(39) + '()')}&company-key={COMPANY_KEY}{APP}"
    sign = sha1(salt + sha1(password) + signed)
    dat = get(f"{BASE}?sign={sign}&salt={salt}{sent}")
    return dat["secret"], dat["token"]


def query(secret, token, action):
    salt = str(int(time.time() * 1000))
    sign = sha1(salt + secret + token + "&action=" + action)
    return get(f"{BASE}?sign={sign}&salt={salt}&token={token}&action={action}")


def main():
    user, password = os.environ.get("SHINEMONITOR_USER"), os.environ.get("SHINEMONITOR_PASSWORD")
    if not user or not password:
        sys.exit("set SHINEMONITOR_USER and SHINEMONITOR_PASSWORD")
    secret, token = login(user, password)

    device = query(secret, token, "webQueryDeviceEs")["device"][0]
    target = f"pn={device['pn']}&devcode={device['devcode']}&devaddr={device['devaddr']}&sn={device['sn']}"
    rows = query(secret, token, f"queryDeviceLastData&{target}&i18n=en_US")

    wanted = ["Timestamp", "PV1 Input Power", "Battery Capacity", "Battery Voltage", "Battery Charging Current",
              "Battery Discharging Current", "Grid voltage", "AC output active power", "Today generation"]
    for row in rows:
        if row.get("title") in wanted:
            print(f"{row['title']:30s} {row.get('val', '')} {row.get('unit', '')}")


if __name__ == "__main__":
    main()
