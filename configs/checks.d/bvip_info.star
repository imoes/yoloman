def main(ctx, params):
    # Discovery mode: yield a single service for this host if the SNMP data exists
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.3967.1.1.1.1"], mutates=False)
        # If we get any output (non-empty stdout), this host has bvip_info data
        if res.stdout.strip():
            return {"changed": False, "msg": "discovered 1 service",
                    "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}
        return {"changed": False, "msg": "no bvip_info data found",
                "data": {"discovery": []}}

    # Check mode: fetch both OIDs (unitName.1, unitID.2)
    res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "localhost",
                   ".1.3.6.1.4.1.3967.1.1.1.1", ".1.3.6.1.4.1.3967.1.1.1.2"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse snmpget output: lines like '.1.3.6.1.4.1.3967.1.1.1.1.0 = STRING: "name"'
    lines = res.stdout.splitlines()
    if len(lines) < 2:
        return {"changed": False, "msg": "incomplete SNMP data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    def extract_string(line):
        # Example: '.1.3.6.1.4.1.3967.1.1.1.1.0 = STRING: "flexidome-001"'
        idx = line.find('STRING: "')
        if idx == -1:
            return ""
        val = line[idx + len('STRING: "'):]
        if val.endswith('"'):
            val = val[:-1]
        return val

    unit_name = extract_string(lines[0])
    unit_id = extract_string(lines[1])

    # Check logic: OK status in both cases; summary differs if names match
    if unit_name == unit_id:
        summary = "Unit Name/ID: " + unit_name
    else:
        summary = "Unit Name: " + unit_name + ", Unit ID: " + unit_id

    return {"changed": False, "msg": summary,
            "data": {"state": "OK", "metrics": {}, "details": ""}}
