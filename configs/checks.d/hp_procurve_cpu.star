def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.11.2.14.11.5.1.9.6.1"
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    util = None
    for line in res.stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        parts = line.split(" = ")
        if len(parts) >= 2:
            value_str = parts[1].strip()
            # Extract numeric value: "INTEGER: 45" -> "45"
            if value_str.startswith("INTEGER: "):
                val = value_str[len("INTEGER: "):].strip()
                if val.isdigit():
                    util = int(val)
                    break
            elif value_str.isdigit():
                util = int(value_str)
                break
    
    if util == None or not ((0 <= util) and (util <= 100)):
        return {
            "changed": False,
            "msg": "CPU utilization data unavailable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    warn = 80.0
    crit = 90.0
    levels = params.get("util", (80.0, 90.0))
    if type(levels) == "list" and len(levels) >= 2:
        warn = float(levels[0])
        crit = float(levels[1])
    elif type(levels) == "dict":
        warn = levels.get("util", 80.0)
        crit = levels.get("util", 90.0)
        if type(warn) == "list" and len(warn) >= 1:
            warn = float(warn[0])
        if type(crit) == "list" and len(crit) >= 1:
            crit = float(crit[0])
    
    state = "CRIT" if util >= crit else ("WARN" if util >= warn else "OK")
    
    return {
        "changed": False,
        "msg": "CPU utilization: %d%%" % util,
        "data": {
            "state": state,
            "metrics": {"util": float(util)},
            "details": ""
        }
    }