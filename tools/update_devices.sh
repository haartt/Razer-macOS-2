#!/bin/zsh
# Regenerates Sources/Mouser/DeviceTable.swift from the latest openrazer source.
set -e
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
git clone --depth 1 -q https://github.com/openrazer/openrazer.git "$TMP/openrazer"
python3 -I tools/parse_driver.py "$TMP/openrazer/driver/razermouse_driver.c" "$TMP/openrazer/driver/razermouse_driver.h" "$TMP/driver.json"
python3 -I tools/parse_daemon.py "$TMP/openrazer/daemon/openrazer_daemon/hardware/mouse.py" "$TMP/daemon.json" > /dev/null
python3 -I tools/generate_devices.py "$TMP/driver.json" "$TMP/daemon.json" Sources/Mouser/DeviceTable.swift tools/device-report.md
