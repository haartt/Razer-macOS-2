"""Read openrazer daemon mouse.py with ast (no execution): per class -> pid, name, methods, dpi max, poll rates."""
import ast, sys, json, re, collections
tree = ast.parse(open(sys.argv[1]).read())
classes = {}
for node in tree.body:
    if not isinstance(node, ast.ClassDef): continue
    attrs = {}
    for st in node.body:
        if isinstance(st, ast.Assign) and len(st.targets) == 1 and isinstance(st.targets[0], ast.Name):
            try: attrs[st.targets[0].id] = ast.literal_eval(st.value)
            except Exception: pass
        if isinstance(st, ast.AugAssign) and isinstance(st.target, ast.Name):  # METHODS += [...]
            try: attrs.setdefault("_aug", {})[st.target.id] = ast.literal_eval(st.value)
            except Exception: pass
    doc = ast.get_docstring(node) or ""
    name = re.search(r'Class for the (Razer .+)', doc)
    classes[node.name] = {"bases": [b.id for b in node.bases if isinstance(b, ast.Name)], "attrs": attrs,
                          "name": name.group(1).strip() if name else None}
def resolve(cn, key, seen=()):
    c = classes.get(cn)
    if not c: return None
    v = c["attrs"].get(key)
    if v is None:
        for b in c["bases"]:
            v = resolve(b, key)
            if v is not None: break
    aug = c["attrs"].get("_aug", {}).get(key)
    if aug is not None: v = (v or []) + aug
    return v
out = []
for cn, c in classes.items():
    pid = resolve(cn, "USB_PID")
    if pid is None or cn.startswith("_"): continue
    out.append({"class": cn, "pid": pid, "name": c["name"] or cn, "methods": resolve(cn, "METHODS") or [],
                "dpi_max": resolve(cn, "DPI_MAX"), "poll_rates": resolve(cn, "POLL_RATES"),
                "wireless": bool(re.search(r'wireless|receiver|dongle', (c["name"] or cn), re.I))})
json.dump(out, open(sys.argv[2], "w"), indent=1)
print(len(out), "mice")
cnt = collections.Counter(m for d in out for m in d["methods"])
print(sorted(cnt.items()))
