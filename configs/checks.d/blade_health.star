def main(ctx, params):
    # Discovery mode: check if this host has the blade_health SNMP section
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
            ".1.3.6.1.4.1.2.3.51.2.2.7.1.0"
        ], mutates=False)
        # If the OID exists (rc==0 and output non-empty), there's one service
        if res.rc == 0 and res.stdout.strip():
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {
                    "discovery": [
                        {"item": "", "params": {}, "metrics": []}
                    ]
                }
            }
        return {
            "changed": False,
            "msg": "no blade health data found",
            "data": {"discovery": []}
        }

    # Check mode: fetch the health state OID
    res = ctx.run([
        "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.2.3.51.2.2.7.1.0"
    ], mutates=False)
    if res.rc != 0 or res.stdout.strip() == "":
        return {
            "changed": False,
            "msg": "unable to retrieve blade health state",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Parse OID output: .1.3.6.1.4.1.2.3.51.2.2.7.1.0 = INTEGER: <state>
    line = ""
    lines = res.stdout.strip().splitlines()
    if len(lines) >= 1:
        line = lines[0]
    parts = []
    if line != "":
        parts = line.split(" = ")
    state_str = ""
    if len(parts) >= 2:
        value_part = parts[1].strip()
        if value_part.startswith("INTEGER: "):
            state_str = value_part[len("INTEGER: "):].strip()
        elif value_part.isdigit():
            state_str = value_part
    if state_str == "" or not state_str.isdigit():
        return {
            "changed": False,
            "msg": "invalid state value: %s" % state_str,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    state = int(state_str)

    # Fetch description OID: .1.3.6.1.4.1.2.3.51.2.2.7.2.1.3.1
    desc_res = ctx.run([
        "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.2.3.51.2.2.7.2.1.3.1"
    ], mutates=False)

    # Extract description from output: .1.3.6.1.4.1.2.3.51.2.2.7.2.1.3.1 = STRING: "..."
    desc = ""
    if desc_res.rc == 0 and desc_res.stdout.strip() != "":
        desc_line = ""
        desc_lines = desc_res.stdout.strip().splitlines()
        if len(desc_lines) >= 1:
            desc_line = desc_lines[0]
        parts = []
        if desc_line != "":
            parts = desc_line.split(" = ")
        if len(parts) >= 2:
            value_part = parts[1].strip()
            if value_part.startswith('STRING: "'):
                desc = value_part[8:-1]  # strip "STRING: \"" and "\""
            elif value_part.startswith('"') and value_part.endswith('"'):
                desc = value_part[1:-1]

    # Determine state based on integer code
    state_name = ""
    summary = ""
    if state == 255:
        state_name = "OK"
        summary = "State is good"
    elif state == 2:
        state_name = "WARN"
        summary = "State is degraded (non critical)"
    elif state == 4:
        state_name = "WARN"
        summary = "State is degraded (system level)"
    elif state == 0:
        state_name = "CRIT"
        summary = "State is critical!"
    else:
        state_name = "UNKNOWN"
        summary = "Undefined state code %d" % state

    if desc != "":
        summary = summary + ": " + desc

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state_name,
            "metrics": {},
            "details": ""
        }
    }
