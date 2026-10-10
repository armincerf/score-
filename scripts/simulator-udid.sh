#!/usr/bin/env bash
# Print the UDID of an iOS simulator named $1 (default "iPhone 17 Pro") on the newest
# installed iOS runtime, creating the device if that runtime has none. Keeps `make test`
# working after a runtime upgrade without hand-editing destinations.
set -euo pipefail
name=${1:-iPhone 17 Pro}
xcrun simctl list -j devices available runtimes > /tmp/simctl-$$.json
trap 'rm -f /tmp/simctl-$$.json' EXIT
python3 -I - "$name" /tmp/simctl-$$.json <<'PY'
import json, subprocess, sys
name, path = sys.argv[1], sys.argv[2]
data = json.load(open(path))
runtimes = [r for r in data.get("runtimes", []) if r.get("platform") == "iOS" and r.get("isAvailable")]
if not runtimes:
    sys.exit("no available iOS simulator runtime; run: xcodebuild -downloadPlatform iOS")
runtime = max(runtimes, key=lambda r: [int(x) for x in r["version"].split(".")])
devices = data.get("devices", {}).get(runtime["identifier"], [])
match = next((d for d in devices if d["name"] == name and d.get("isAvailable", True)), None)
if match is None:
    types = subprocess.run(["xcrun", "simctl", "list", "-j", "devicetypes"], capture_output=True, text=True, check=True).stdout
    dtype = next((t["identifier"] for t in json.loads(types)["devicetypes"] if t["name"] == name), None)
    if dtype is None:
        sys.exit(f"unknown simulator device type '{name}'")
    udid = subprocess.run(["xcrun", "simctl", "create", name, dtype, runtime["identifier"]], capture_output=True, text=True, check=True).stdout.strip()
    print(f"created {name} on {runtime['name']}", file=sys.stderr)
    print(udid)
else:
    print(match["udid"])
PY
