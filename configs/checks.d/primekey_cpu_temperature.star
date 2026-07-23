def main(ctx, params):
    # Detect PrimeKey device via sysObjectID
    res_detect = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                          "-On", params.get("host", "localhost"),
                          ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res_detect.rc != 0:
        return {"changed": False, "msg": "SNMP query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    oid_line = res_detect.stdout.strip()
    # Expected: .1.3.6.1.4.1.8072.3.2.10
    expected_oid = ".1.3.6.1.4.1.8072.3.2.10"
    if not oid_line.endswith(" = " + expected_oid):
        # Not a PrimeKey device -> no service
        return {"changed": False, "msg": "not a PrimeKey device",
                "data": {"discovery": []}}

    if params.get("_discover"):
        # Discover: fetch CPU temperature OID
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"),
                       ".1.3.6.1.4.1.22408.1.1.2.1.3.99.112.117.1"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP query failed for CPU temp",
                    "data": {"discovery": []}}
        # Output format: OID = STRING: "<value>" or OID = INTEGER: <value>
        line = res.stdout.strip()
        if "INTEGER:" in line:
            temp_str = line.split("INTEGER:")[1].strip()
        elif "Gauge32:" in line:
            temp_str = line.split("Gauge32:")[1].strip()
        elif "Counter32:" in line:
            temp_str = line.split("Counter32:")[1].strip()
        else:
            return {"changed": False, "msg": "cannot parse temperature value",
                    "data": {"discovery": []}}
        if not temp_str.replace(".", "").replace("-", "").isdigit():
            return {"changed": False, "msg": "cannot parse temperature value",
                    "data": {"discovery": []}}
        cpu_temp = float(temp_str)
        return {"changed": False, "msg": "discovered 1 CPU temperature",
                "data": {"discovery": [
                    {"item": "CPU", "params": {"levels": (20.0, 50.0)},
                     "metrics": ["temperature"]}]}}
    
    # Check mode
    item = params.get("item", "")
    if item != "CPU":
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch current temperature
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"),
                   ".1.3.6.1.4.1.22408.1.1.2.1.3.99.112.117.1"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP query failed for CPU temp",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    line = res.stdout.strip()
    if "INTEGER:" in line:
        temp_str = line.split("INTEGER:")[1].strip()
    elif "Gauge32:" in line:
        temp_str = line.split("Gauge32:")[1].strip()
    elif "Counter32:" in line:
        temp_str = line.split("Counter32:")[1].strip()
    else:
        return {"changed": False, "msg": "cannot parse temperature value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not temp_str.replace(".", "").replace("-", "").isdigit():
        return {"changed": False, "msg": "cannot parse temperature value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    temperature = float(temp_str)

    # Apply thresholds
    levels = params.get("levels", (20.0, 50.0))
    warn = levels[0] if isinstance(levels, (list, tuple)) and len(levels) >= 2 else 20.0
    crit = levels[1] if isinstance(levels, (list, tuple)) and len(levels) >= 2 else 50.0

    # Check against levels (upper bound: warn/crit thresholds are upper limits)
    if temperature >= crit:
        state = "CRIT"
    elif temperature >= warn:
        state = "WARN"
    else:
        state = "OK"

    msg = "CPU: %f C" % temperature
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"temperature": temperature}, "details": ""}}