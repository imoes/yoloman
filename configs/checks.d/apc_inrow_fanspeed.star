def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Check for ATS device detection: sysObjectID starts with .1.3.6.1.4.1.318
        sys_object_id = ""
        res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if res.rc == 0:
            # Parse output: ".1.3.6.1.2.1.1.2.0 = STRING: ".1.3.6.1.4.1.318.1.3.11"
            lines = res.stdout.strip().splitlines()
            for line in lines:
                if "=" in line:
                    sys_object_id = line.split("=", 1)[1].strip()
                    break
        # Check if sysObjectID starts with ".1.3.6.1.4.1.318"
        if sys_object_id.startswith(".1.3.6.1.4.1.318"):
            # This is an ATS device; check fanspeed OID is accessible
            res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.318.1.1.13.3.2.2.2.16.0"], mutates=False)
            if res.rc == 0:
                return {"changed": False, "msg": "discovered Fanspeed service",
                        "data": {"discovery": [{"item": "", "params": {}, "metrics": ["fan_perc"]}]}}

        # Fallback: no ATS detected or SNMP failed
        return {"changed": False, "msg": "no Fanspeed service found",
                "data": {"discovery": []}}

    # Check mode for Fanspeed
    # Read fanspeed via SNMP
    res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.318.1.1.13.3.2.2.2.16.0"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse output: ".1.3.6.1.4.1.318.1.1.13.3.2.2.2.16.0 = INTEGER: 500"
    line = res.stdout.strip()
    value_str = ""
    if "=" in line:
        value_str = line.split("=", 1)[1].strip()
    # Extract integer from value string (remove quotes if present, get numeric part)
    for part in value_str.split():
        if part.isdigit() or (part.startswith("-") and part[1:].isdigit()):
            value_str = part
            break
    if not value_str.isdigit() and not (value_str.startswith("-") and value_str[1:].isdigit()):
        return {"changed": False, "msg": "invalid fanspeed value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw_value = int(value_str)

    # Convert to percentage: raw_value / 10.0
    fanspeed = float(raw_value) / 10.0

    # Return OK status (no thresholds defined in original check)
    return {"changed": False, "msg": "Current: %f%%" % fanspeed,
            "data": {"state": "OK", "metrics": {"fan_perc": fanspeed}, "details": ""}}
