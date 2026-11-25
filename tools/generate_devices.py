"""Generate Sources/Mouser/DeviceTable.swift from openrazer data.

Usage: python3 -I tools/generate_devices.py <driver_table.json> <daemon_table.json> <out.swift> <report.md>
Inputs come from parse_driver.py (razermouse_driver.c) and parse_daemon.py (daemon hardware/mouse.py).

Only command families that Mouser implements are emitted; anything else is left out and listed in the report.
Derived from openrazer (GPL-2.0-or-later), https://github.com/openrazer/openrazer
"""
import json, sys

TESTED = {0x008C}  # verified on real hardware

drv = json.load(open(sys.argv[1]))
daemon = json.load(open(sys.argv[2]))
H = drv["handlers"]
pid_names = {}
for name, value in drv["pids"].items():
    pid_names.setdefault(value, name)

skipped = []  # (mouse, feature, reason)


def entry(handler, name):
    h = H.get(handler)
    if not h:
        return None
    return h["models"].get(name)


def single_tid(handler, name, switch=None):
    """Transaction id used by this model in this handler, or None if absent/ambiguous."""
    h = H.get(handler)
    if not h:
        return None
    if switch is not None:
        sw = h["per_switch_tid"]
        tids = sw[switch].get(name, []) if switch < len(sw) else []
    else:
        e = h["models"].get(name)
        if e is None:
            return None
        tids = e["tid"] or h["common"]["tid"]
    return int(tids[0], 16) if len(tids) == 1 else None


def builders(handler, name):
    e = entry(handler, name)
    if e is None:
        return []
    return e["builders"] or H[handler]["common"]["builders"]


LED_IDS = {"ZERO_LED": 0x00, "SCROLL_WHEEL_LED": 0x01, "LOGO_LED": 0x04, "BACKLIGHT_LED": 0x05,
           "RIGHT_SIDE_LED": 0x10, "LEFT_SIDE_LED": 0x11}
ZONE_LED = {"logo": 0x04, "scroll": 0x01, "left": 0x11, "right": 0x10, "backlight": 0x05}


def led_for(handler, name, zcase, fam):
    """LED id this command targets: zone wrappers pass a fixed LED; whole-device commands name it per model."""
    if zcase != "matrix":
        return ZONE_LED[zcase]
    leds = entry(handler, name)["leds"]
    if len(leds) == 1 and leds[0] in LED_IDS:
        return LED_IDS[leds[0]]
    if not leds and fam == "standardMatrix":
        return 0x00  # standard matrix commands carry no LED id
    return None


def light_family(bs):
    s = " ".join(bs)
    if "razer_chroma_extended_matrix_effect" in s:
        return "extended"
    if "razer_chroma_mouse_extended_matrix_effect" in s:
        return "mouseExtended"
    if "razer_chroma_standard_matrix_effect" in s:
        return "standardMatrix"
    if "razer_chroma_standard_set_led" in s:
        return "standardLED"
    return None


ZONES = [  # (swift case, daemon method prefix, handler suffix, brightness method)
    ("matrix", "", "", "get_brightness"),
    ("logo", "logo_", "_common", "get_logo_brightness"),
    ("scroll", "scroll_", "_common", "get_scroll_brightness"),
    ("left", "left_", "_common", "get_left_brightness"),
    ("right", "right_", "_common", "get_right_brightness"),
    ("backlight", "backlight_", "_common", "get_backlight_brightness"),
]
EFFECTS = [  # (swift case, daemon zone method, daemon matrix method, driver handler stem)
    ("off", "none", "set_none_effect", "none"),
    ("staticColor", "static", "set_static_effect", "static"),
    ("breathing", "breath_single", "set_breath_single_effect", "breath"),
    ("spectrum", "spectrum", "set_spectrum_effect", "spectrum"),
]


def hexb(v):
    return "0x%02X" % v


def swift_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


out_specs = []
seen = set()
for d in sorted(daemon, key=lambda x: x["name"].lower()):
    pid = d["pid"]
    if pid in seen:
        continue
    seen.add(pid)
    name = pid_names.get(pid)
    title = d["name"]
    if name is None:
        skipped.append((title, "all", "not in driver"))
        continue
    m = set(d["methods"])
    max_dpi = d["dpi_max"] or 0

    fw = single_tid("razer_attr_read_firmware_version", name) or 0xFF

    dpi = "nil"
    if "set_dpi_xy" in m or "set_dpi_xy_byte" in m:
        bs = builders("razer_attr_write_dpi", name)
        tid = None
        for sw in range(len(H["razer_attr_write_dpi"]["per_switch_tid"])):
            tid = tid or single_tid("razer_attr_write_dpi", name, sw)
        if "razer_chroma_misc_set_dpi_xy_byte" in bs and tid is not None:
            dpi = f".init(byteFormat: true, tid: {hexb(tid)})"
        elif "razer_chroma_misc_set_dpi_xy" in bs and tid is not None:
            dpi = f".init(byteFormat: false, tid: {hexb(tid)})"
        else:
            skipped.append((title, "DPI", "special command (%s)" % ", ".join(bs) or "unknown"))

    stages = "nil"
    if "set_dpi_stages" in m:
        tid = single_tid("razer_attr_write_dpi_stages", name)
        if tid is not None:
            stages = hexb(tid)
        else:
            skipped.append((title, "DPI stages", "no transaction id"))

    poll = "nil"
    if "set_poll_rate" in m:
        bs = builders("razer_attr_write_poll_rate", name)
        rates = d["poll_rates"] or [125, 500, 1000]
        tid = single_tid("razer_attr_write_poll_rate", name, 0)
        second = single_tid("razer_attr_write_poll_rate", name, 1)
        rates_s = "[" + ", ".join(str(r) for r in rates) + "]"
        if "razer_chroma_misc_set_polling_rate2" in bs and tid is not None:
            sec = hexb(second) if second is not None else "nil"
            poll = f".init(hyper: true, tid: {hexb(tid)}, secondTID: {sec}, rates: {rates_s})"
        elif "razer_chroma_misc_set_polling_rate" in bs and tid is not None:
            poll = f".init(hyper: false, tid: {hexb(tid)}, secondTID: nil, rates: {rates_s})"
        else:
            skipped.append((title, "polling rate", "special command (%s)" % ", ".join(bs) or "unknown"))

    battery = hexb(single_tid("razer_attr_read_charge_level", name)) if "get_battery" in m and single_tid("razer_attr_read_charge_level", name) is not None else "nil"
    charging = hexb(single_tid("razer_attr_read_charge_status", name)) if "is_charging" in m and single_tid("razer_attr_read_charge_status", name) is not None else "nil"

    zones = []
    for zcase, prefix, suffix, bright_method in ZONES:
        effects = []
        for ecase, zmethod, mmethod, stem in EFFECTS:
            method = mmethod if zcase == "matrix" else f"set_{prefix}{zmethod}"
            if method not in m:
                continue
            handler = f"razer_attr_write_matrix_effect_{stem}{suffix}"
            fam = light_family(builders(handler, name))
            tid = single_tid(handler, name)
            if fam == "standardMatrix" and zcase != "matrix":
                fam = None
            led = led_for(handler, name, zcase, fam) if fam else None
            if fam is None or tid is None or led is None:
                skipped.append((title, f"{zcase} {ecase}", "special command"))
                continue
            effects.append(f".{ecase}: .init(family: .{fam}, tid: {hexb(tid)}, led: {hexb(led)})")
        bright = "nil"
        if bright_method in m:
            wh = "razer_attr_write_matrix_brightness" if zcase == "matrix" else "razer_attr_write_led_brightness"
            bs = " ".join(builders(wh, name))
            tid = single_tid(wh, name)
            fam = "extended" if "razer_chroma_extended_matrix_brightness" in bs else \
                  "standardLED" if "razer_chroma_standard_set_led_brightness" in bs else None
            led = led_for(wh, name, zcase, fam) if fam else None
            if fam and tid is not None and led is not None:
                bright = f".init(family: .{fam}, tid: {hexb(tid)}, led: {hexb(led)})"
            else:
                skipped.append((title, f"{zcase} brightness", "special command"))
        if effects or bright != "nil":
            eff = "[" + ", ".join(effects) + "]" if effects else "[:]"
            zones.append(f".init(zone: .{zcase}, effects: {eff}, brightness: {bright})")

    out_specs.append(
        f"        DeviceSpec(productID: 0x{pid:04X}, name: {swift_str(title)}, maxDPI: {max_dpi}, "
        f"tested: {'true' if pid in TESTED else 'false'},\n"
        f"                   firmwareTID: {hexb(fw)}, dpi: {dpi}, stagesTID: {stages}, poll: {poll},\n"
        f"                   batteryTID: {battery}, chargingTID: {charging},\n"
        f"                   zones: [{', '.join(zones)}]),"
    )

swift = f"""// GENERATED by tools/generate_devices.py — do not edit by hand.
// Device data derived from openrazer (https://github.com/openrazer/openrazer), GPL-2.0-or-later.

extension DeviceCatalog {{
    static let all: [DeviceSpec] = [
{chr(10).join(out_specs)}
    ]
}}
"""
open(sys.argv[3], "w").write(swift)

with open(sys.argv[4], "w") as r:
    r.write(f"# Device table report\n\n{len(out_specs)} mice generated. Features left out (not implemented in Mouser):\n\n")
    r.write("| Mouse | Feature | Reason |\n|---|---|---|\n")
    for t, f, why in skipped:
        r.write(f"| {t} | {f} | {why} |\n")
print(len(out_specs), "mice,", len(skipped), "skipped features")
