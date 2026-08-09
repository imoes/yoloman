def _detect_device(ctx, community, host):
    oid = ".1.3.6.1.2.1.1.2.0"
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return None
    val = res.stdout.strip()
    if val == "" or val == "No Such Name" or val == "TIMEOUT":
        return None
    return val

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")

    if params.get("_discover"):
        sysoid = _detect_device(ctx, community, host)
        if sysoid == None:
            return {"changed": False, "msg": "no Fujitsu storage device detected",
                    "data": {"discovery": []}}
        devices = {
            ".1.3.6.1.4.1.211.1.21.1.60": ".2.5.2.1",
            ".1.3.6.1.4.1.211.1.21.1.100": ".2.9.2.1",
            ".1.3.6.1.4.1.211.1.21.1.101": ".2.9.2.1",
            ".1.3.6.1.4.1.211.1.21.1.150": ".2.5.2.1",
            ".1.3.6.1.4.1.211.1.21.1.153": ".2.5.2.1",
        }
        if sysoid not in devices:
            return {"changed": False, "msg": "unsupported Fujitsu device: %s" % sysoid,
                    "data": {"discovery": []}}
        col_oid = devices[sysoid] + ".1"
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_oid], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed for capacitors index",
                    "data": {"discovery": []}}
        found = {}
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid_part, value = parts[0], parts[1]
            idx = oid_part[len(col_oid) + 1:]
            if idx == "":
                continue
            found[idx] = value
        status_col = devices[sysoid] + ".3"
        out = []
        for idx in sorted(found.keys()):
            stres = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, status_col + "." + idx], mutates=False)
            status = stres.stdout.strip() if stres.rc == 0 else ""
            if status == "4":
                continue
            out.append({"item": idx, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d system capacitor units" % len(out),
                "data": {"discovery": out}}

    sysoid = _detect_device(ctx, community, host)
    if sysoid == None:
        return {"changed": False, "msg": "no Fujitsu storage device detected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    devices = {
        ".1.3.6.1.4.1.211.1.21.1.60": ".2.5.2.1",
        ".1.3.6.1.4.1.211.1.21.1.100": ".2.9.2.1",
        ".1.3.6.1.4.1.211.1.21.1.101": ".2.9.2.1",
        ".1.3.6.1.4.1.211.1.21.1.150": ".2.5.2.1",
        ".1.3.6.1.4.1.211.1.21.1.153": ".2.5.2.1",
    }
    if sysoid not in devices:
        return {"changed": False, "msg": "unsupported Fujitsu device: %s" % sysoid,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    status_col = devices[sysoid] + ".3"
    stres = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, status_col + "." + item], mutates=False)
    if stres.rc != 0:
        return {"changed": False, "msg": "no data for system capacitor unit %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    status = stres.stdout.strip()
    status_map = {
        "1": {"state": "OK", "summary": "Normal"},
        "2": {"state": "CRIT", "summary": "Alarm"},
        "3": {"state": "WARN", "summary": "Warning"},
        "4": {"state": "CRIT", "summary": "Invalid"},
        "5": {"state": "CRIT", "summary": "Maintenance"},
        "6": {"state": "CRIT", "summary": "Undefined"},
    }
    entry = status_map.get(status)
    if entry == None:
        return {"changed": False, "msg": "System Capacitor Unit %s: Unknown (status %s)" % (item, status),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "System Capacitor Unit %s: %s" % (item, entry["summary"]),
            "data": {"state": entry["state"], "metrics": {}, "details": ""}}