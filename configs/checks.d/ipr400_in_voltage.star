def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "1")
    if params.get("_discover"):
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"], mutates=False)
        if res.rc != 0 or res.skipped:
            return {"changed": False, "msg": "snmp unreachable", "data": {"discovery": []}}
        sysdescr = res.stdout.strip()
        if not sysdescr.startswith("ipr voip device ipr400"):
            return {"changed": False, "msg": "not an ipr400 device", "data": {"discovery": []}}
        res2 = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.27053.1.4.5.10.0"], mutates=False)
        if res2.rc != 0 or res2.skipped:
            return {"changed": False, "msg": "no voltage data", "data": {"discovery": []}}
        raw = res2.stdout.strip()
        if raw == "" or raw.startswith("No"):
            return {"changed": False, "msg": "no voltage data", "data": {"discovery": []}}
        discovery = [{"item": "1", "params": {"levels_lower": (12.0, 11.0)}, "metrics": ["in_voltage"]}]
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.27053.1.4.5.10.0"], mutates=False)
    if res.rc != 0 or res.skipped:
        return {"changed": False, "msg": "unable to read voltage", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    raw = res2.stdout.strip()
    if raw == "" or raw.startswith("No"):
        return {"changed": False, "msg": "no voltage data available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    power = float(raw) if _is_numeric(raw) else None
    if power == None:
        return {"changed": False, "msg": "invalid voltage value", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    levels_lower = params.get("levels_lower", (12.0, 11.0))
    warn, crit = levels_lower[0], levels_lower[1]
    levels_upper = params.get("levels_upper", (None, None))
    warn_upper, crit_upper = levels_upper[0], levels_upper[1]
    infotext = "in voltage: %fV" % power
    if power <= crit:
        state = "CRIT"
        summary = "%s, (warn/crit below %sV/%sV)" % (infotext, warn, crit)
    elif crit_upper != None and power >= crit_upper:
        state = "CRIT"
        summary = "%s, (warn/crit at or above %sV/%sV)" % (infotext, warn_upper, crit_upper)
    elif power <= warn:
        state = "WARN"
        summary = "%s, (warn/crit below %sV/%sV)" % (infotext, warn, crit)
    elif warn_upper != None and power >= warn_upper:
        state = "WARN"
        summary = "%s, (warn/crit at or above %sV/%sV)" % (infotext, warn_upper, crit_upper)
    else:
        state = "OK"
        summary = infotext
    return {"changed": False, "msg": summary, "data": {"state": state, "metrics": {"in_voltage": power}, "details": ""}}

def _is_numeric(s):
    stripped = s.lstrip("-")
    if stripped == "":
        return False
    parts = stripped.split(".")
    if len(parts) == 1:
        return parts[0].isdigit()
    return parts[0].isdigit() and parts[1].isdigit()