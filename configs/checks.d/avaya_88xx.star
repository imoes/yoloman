def _temp_state(value, warn, crit):
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"

def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn",
                       host, ".1.3.6.1.4.1.2272.1.4.7.1.1"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no avaya_88xx data", "data": {"discovery": []}}
        rows = {}
        for line in res.stdout.splitlines():
            parts = line.split(None, 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            val = parts[1].strip()
            oid_parts = oid.split(".")
            col = oid_parts[0]
            idx = oid_parts[1]
            if col not in ("2", "3"):
                continue
            entry = rows.get(idx)
            if entry == None:
                entry = {"fanstate": "", "temp": ""}
                rows[idx] = entry
            if col == "2":
                entry["fanstate"] = val
            elif col == "3":
                entry["temp"] = val
        discovery = []
        for idx in rows:
            r = rows[idx]
            if r["temp"]:
                discovery.append({
                    "item": idx,
                    "params": {"levels": (55.0, 60.0)},
                    "metrics": ["temperature"],
                    "service_labels": {},
                })
            if r["fanstate"]:
                discovery.append({
                    "item": idx,
                    "params": {},
                    "metrics": [],
                    "service_labels": {"service_type": "fan"},
                })
        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}
    sub = params.get("_sub", "temp")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    idx = params.get("item", "")
    if sub == "fan":
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv",
                       host, ".1.3.6.1.4.1.2272.1.4.7.1.1.2." + idx], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no fan state for %s" % idx,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        state_map = {
            "1": ("UNKNOWN", "Reported Unknown"),
            "2": ("OK", "Running"),
            "3": ("CRIT", "Down"),
        }
        st, text = state_map.get(res.stdout.strip(), ("UNKNOWN", "Unknown state"))
        return {"changed": False, "msg": "Fan %s %s" % (idx, text),
                "data": {"state": st, "metrics": {}, "details": ""}}
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv",
                   host, ".1.3.6.1.4.1.2272.1.4.7.1.1.3." + idx], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no temperature for %s" % idx,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    raw = res.stdout.strip()
    reading = int(raw) if raw.isdigit() else 0
    levels = params.get("levels", (55.0, 60.0))
    warn = levels[0] if isinstance(levels, (list, tuple)) and len(levels) >= 1 else 55.0
    crit = levels[1] if isinstance(levels, (list, tuple)) and len(levels) >= 2 else 60.0
    warn = params.get("warn", warn)
    crit = params.get("crit", crit)
    st = _temp_state(reading, warn, crit)
    return {"changed": False, "msg": "Temperature Fan %s: %d C" % (idx, reading),
            "data": {"state": st, "metrics": {"temperature": reading,
                      "warn": warn, "crit": crit}, "details": ""}}