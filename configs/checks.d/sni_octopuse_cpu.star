def main(ctx, params):
    if params.get("_discover"):
        # Discovery: check if device is an SNI Octopuse by probing sysDescr
        res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "localhost", "1.3.6.1.2.1.1.1.0"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items (SNMP not available)",
                    "data": {"discovery": []}}
        if "agent for hipath" not in res.stdout.lower():
            return {"changed": False, "msg": "discovered 0 items (not SNI Octopuse device)",
                    "data": {"discovery": []}}
        # One service exists
        return {"changed": False, "msg": "discovered 1 service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": ["util"]}]}}

    # Check mode (single-service check)
    res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "localhost", "1.3.6.1.4.1.231.7.2.9.1.7.0"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    # Parse value: expect something like "INTEGER: 42"
    line = res.stdout.strip()
    if "INTEGER" in line:
        parts = line.split(":")
        if len(parts) < 2:
            return {"changed": False, "msg": "unable to parse CPU value",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        cpu_str = parts[1].strip()
    else:
        return {"changed": False, "msg": "unexpected SNMP output format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if not cpu_str.isdigit():
        return {"changed": False, "msg": "CPU value is not an integer",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    cpu_perc = int(cpu_str)

    # Determine state (no thresholds in this check; always OK)
    state = "OK"
    return {"changed": False, "msg": "CPU utilization is %d%%" % cpu_perc,
            "data": {"state": state, "metrics": {"util": float(cpu_perc)}, "details": ""}}
