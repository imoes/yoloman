def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
        }

    # Probe the door status via SNMP
    # OID: .1.3.6.1.4.1.3697.1.10.10.1.15.2.0
    res = ctx.run([
        "snmpget", "-On", "-v2c", "-c", "public", "localhost",
        "1.3.6.1.4.1.3697.1.10.10.1.15.2.0"
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse the output: should be something like:
    # .1.3.6.1.4.1.3697.1.10.10.1.15.2.0 = STRING: "1" or "2"
    line = res.stdout.strip()
    if not line:
        return {
            "changed": False,
            "msg": "empty SNMP response",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract the string value (everything after the =)
    parts = line.split(" = ", 1)
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "unexpected SNMP response format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    value_str = parts[1].strip().strip('"')
    state_map = {
        "1": ("CRIT", "Library door open"),
        "2": ("OK", "Library door closed")
    }
    
    if value_str in state_map:
        state_str, summary = state_map[value_str]
        return {
            "changed": False,
            "msg": summary,
            "data": {"state": state_str, "metrics": {}, "details": ""}
        }
    else:
        return {
            "changed": False,
            "msg": "Library door unknown",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
