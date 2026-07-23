def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": ["connections"]}]}
        }

    # Single-service check: item is always ""
    res = ctx.run([
        "snmpget", "-Ovq", "-On", "-v2c", "-c", "public",
        "1.3.6.1.4.1.14823.2.2.1.1.3.1"
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    value_str = res.stdout.strip()
    connected_aps = int(value_str) if value_str.isdigit() or (value_str.startswith("-") and value_str[1:].isdigit()) else -1
    
    if connected_aps == -1:
        return {
            "changed": False,
            "msg": "invalid SNMP value: " + value_str,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Checkmk's check_levels defaults (no levels specified)
    state = "OK"
    msg = "Connections: %d" % connected_aps
    
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {"connections": connected_aps}, "details": ""}
    }
