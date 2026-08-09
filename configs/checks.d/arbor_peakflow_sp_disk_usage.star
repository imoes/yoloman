def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        # Probe for the real Arbor Peakflow SP device (its disk usage OID).
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv",
                       host, ".1.3.6.1.4.1.9694.1.4.2.1.4.0"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            # Device not present / not an Arbor Peakflow SP.
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        val = res.stdout.strip()
        if not val.lstrip("-").isdigit():
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "/",
                     "params": {"levels": (80, 90)},
                     "metrics": ["disk_utilization"]}]}}
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv",
                   host, ".1.3.6.1.4.1.9694.1.4.2.1.4.0"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no Arbor Peakflow SP disk usage data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    raw = res.stdout.strip()
    if not raw.lstrip("-").isdigit():
        return {"changed": False,
                "msg": "invalid disk usage value: %s" % raw,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    usage = int(raw)
    levels = params.get("levels", (80, 90))
    # levels_upper semantics: warn if value >= warn, crit if value >= crit.
    crit = levels[1] if len(levels) > 1 else (levels[0] if len(levels) == 1 else 90)
    warn = levels[0] if len(levels) > 0 else 80
    if usage >= crit:
        state = "CRIT"
    elif usage >= warn:
        state = "WARN"
    else:
        state = "OK"
    return {"changed": False, "msg": "Disk usage %d%%" % usage,
            "data": {"state": state,
                     "metrics": {"disk_utilization": float(usage) / 100.0},
                     "details": ""}}