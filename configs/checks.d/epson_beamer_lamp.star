def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.1248.4.1.1.1.1.0"
        ], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "snmpwalk failed or empty",
                    "data": {"discovery": []}}
        # Checkmk detect: .1.3.6.1.2.1.1.2.0 (sysObjectID) must contain "1248"
        # We approximate by checking if we got a value at our OID (indicating presence)
        # and assume device matches if we got at least one line
        lines = res.stdout.splitlines()
        if not lines:
            return {"changed": False, "msg": "no data from SNMP",
                    "data": {"discovery": []}}
        # At least one SNMP value found -> service exists
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {"levels": (1000*3600, 1500*3600)},
                                        "metrics": ["operation_time"]}]}}
    
    # Check mode (one item, always "")
    res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.1248.4.1.1.1.1.0"
    ], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "snmpget failed or empty",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    # Parse "OID = INTEGER: value"
    line = res.stdout.strip()
    if "=" not in line:
        return {"changed": False, "msg": "unparseable snmp output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    value_str = line.split(":")[-1].strip()
    if not value_str.isdigit():
        return {"changed": False, "msg": "invalid lamp time value: " + value_str,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    hours = int(value_str)
    lamp_time = hours * 3600
    warn, crit = params.get("levels", (1000*3600, 1500*3600))
    if lamp_time >= crit:
        state = "CRIT"
    elif lamp_time >= warn:
        state = "WARN"
    else:
        state = "OK"
    return {"changed": False, "msg": "Operation time: %d h" % hours,
            "data": {"state": state, "metrics": {"operation_time": lamp_time}, "details": ""}}
