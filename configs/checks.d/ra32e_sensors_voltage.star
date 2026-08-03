def _voltage_state(value, warn, crit):
    if value <= warn:
        if value <= crit:
            return "CRIT"
        return "WARN"
    return "OK"

def main(ctx, params):
    if params.get("_discover"):
        base = ".1.3.6.1.4.1.20916.1.8.1.2"
        res = ctx.run(["snmpwalk", "-v2c", "-c",
                       params.get("community", "public"), "-Oqn",
                       params.get("host", "localhost"), base],
                      mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no roomalert32e voltage sensors (snmpwalk failed)",
                    "data": {"discovery": []}}
        rows = {}
        for line in res.stdout.split("\n"):
            if not line:
                continue
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            val = line[sp+1:]
            rest = oid[len(base)+1:]
            parts = rest.split(".")
            if len(parts) >= 2:
                col = parts[0]
                idx = parts[1]
                rows.setdefault(idx, {})[col] = val
        out = []
        for idx in sorted(rows.keys(), key=lambda x: int(x)):
            cols = rows[idx]
            col3 = cols.get("3")
            if col3 == None:
                continue
            if not col3.lstrip("-").isdigit():
                continue
            out.append({"item": "Sensor %s" % str(int(idx)+1),
                        "params": {"voltage": (210, 180)},
                        "metrics": ["voltage"]})
        return {"changed": False,
                "msg": "discovered %d voltage sensors" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    snum_str = item.replace("Sensor ", "")
    snum = int(snum_str) - 1 if snum_str.isdigit() else -1
    if snum < 0:
        return {"changed": False, "msg": "invalid item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    idx = str(snum)
    base = ".1.3.6.1.4.1.20916.1.8.1.2"
    oid = base + ".3." + idx
    res = ctx.run(["snmpget", "-v2c", "-c",
                   params.get("community", "public"), "-Oqv",
                   params.get("host", "localhost"), oid],
                  mutates=False)
    if res.rc != 0:
        return {"changed": False,
                "msg": "no voltage reading for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    val = res.stdout.strip()
    if not val:
        return {"changed": False,
                "msg": "empty voltage for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    value = float(val)
    levels = params.get("voltage", (210, 180))
    warn = levels[0] if isinstance(levels, (list, tuple)) and len(levels) >= 2 else 210
    crit = levels[1] if isinstance(levels, (list, tuple)) and len(levels) >= 2 else 180
    state = _voltage_state(value, warn, crit)
    return {"changed": False,
            "msg": "Voltage %s: %s V" % (item, str(value)),
            "data": {"state": state,
                     "metrics": {"voltage": value},
                     "details": "voltage %s V (warn<=%s, crit<=%s)" % (str(value), str(warn), str(crit))}}