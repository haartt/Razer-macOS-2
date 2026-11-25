"""Parse openrazer razermouse_driver.c: per attr handler, map USB PID name -> builders, transaction ids, LED ids.
Handles several switch(device->usb_pid) blocks per function and builders outside switches ("common")."""
import re, sys, json
src = open(sys.argv[1]).read()
hdr = open(sys.argv[2]).read()
pids = {m[0]: int(m[1], 16) for m in re.findall(r'#define\s+(USB_DEVICE_ID_RAZER_\w+)\s+(0x[0-9A-Fa-f]+)', hdr)}
BUILDER = r'\b(razer_chroma_\w+|razer_\w+_(?:get|set)_\w+|deathadder\w+|razer_get_\w+|razer_set_\w+)\s*\('
def block(s, i):  # s[i] == '{' -> index after matching '}'
    depth = 0
    while True:
        depth += (s[i] == '{') - (s[i] == '}'); i += 1
        if depth == 0: return i
def info(code):
    return (set(re.findall(BUILDER, code)), set(t.lower() for t in re.findall(r'transaction_id\.id\s*=\s*(0x[0-9A-Fa-f]+)', code)),
            set(re.findall(r'\b([A-Z_]+_LED)\b', code)))
out = {}
for m in re.finditer(r'^static (?:ssize_t|int|void) (razer_attr_\w+)\([^)]*\)\s*\{', src, re.M):
    end = block(src, m.end() - 1); body = src[m.end():end - 1]
    switches = []; rest = body
    for sm in re.finditer(r'switch\s*\(\s*device->usb_pid\s*\)\s*\{', body):
        e = block(body, sm.end() - 1); switches.append(body[sm.end():e - 1])
    if not switches: continue
    for sw in switches: rest = rest.replace(sw, '')
    common = info(rest)
    table = {}; per_switch = []
    for si, sw in enumerate(switches):
        ps = {}; per_switch.append(ps)
        parts = re.split(r'((?:\s*case\s+USB_DEVICE_ID_\w+\s*:)+|\s*default\s*:)', sw)
        for k in range(1, len(parts) - 1, 2):
            labels = re.findall(r'case\s+(USB_DEVICE_ID_\w+)\s*:', parts[k]) or ['default']
            b, t, l = info(parts[k + 1])
            for lab in labels:
                ps[lab] = sorted(t)
                e = table.setdefault(lab, [set(), set(), set()])
                e[0] |= b; e[1] |= t; e[2] |= l
    out[m.group(1)] = {"common": {"builders": sorted(common[0]), "leds": sorted(common[2]), "tid": sorted(common[1])}, "per_switch_tid": per_switch,
                       "models": {k: {"builders": sorted(v[0]), "tid": sorted(v[1]), "leds": sorted(v[2])} for k, v in table.items()}}
json.dump({"pids": pids, "handlers": out}, open(sys.argv[3], "w"), indent=1)
print(len(pids), "pids,", len(out), "handlers")
