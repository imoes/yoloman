def main(ctx, params):
    # Discovery mode: yield exactly one service (single-service check)
    if params.get("_discover"):
        # Probe the Stormshield SNMP OIDs (read-only, no mutates=True)
        res = ctx.run([
            "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
            ".1.3.6.1.4.1.11256.1.0"
        ], mutates=False)
        # If snmpwalk fails or returns nothing, the check doesn't apply
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        # For simplicity, assume the check applies if any Stormshield OID responds
        # (We'll rely on the agent's own discovery logic in real deployments)
        return {"changed": False, "msg": "discovered 1 items",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}

    # Check mode: fetch the five SNMP OIDs for Stormshield info
    res = ctx.run([
        "snmpget", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.11256.1.0.1",
        ".1.3.6.1.4.1.11256.1.0.2",
        ".1.3.6.1.4.1.11256.1.0.3",
        ".1.3.6.1.4.1.11256.1.0.4",
        ".1.3.6.1.4.1.11256.1.0.5"
    ], mutates=False)

    # If SNMP query fails, return UNKNOWN state
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse snmpget output (format: OID = STRING:"value" or OID = STRING: value)
    lines = res.stdout.splitlines()
    values = []
    for line in lines:
        if not line.strip():
            continue
        # Split at '=' to get value part
        parts = line.strip().split("=", 1)
        if len(parts) == 2:
            v = parts[1].strip()
            # Strip quotes if present (snmpget typically returns "value" or value)
            if v.startswith('"') and v.endswith('"'):
                v = v[1:-1]
            elif v.startswith('STRING:'):
                v = v[7:].strip().strip('"')
            values.append(v)

    # Expect exactly 5 values: model, version, serial, sysname, syslanguage
    if len(values) != 5:
        return {
            "changed": False,
            "msg": "unexpected SNMP output format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    model, version, serial, sysname, syslanguage = values
    summary = "Model: %s, Version: %s, Serial: %s, SysName: %s, SysLanguage: %s" % (
        model, version, serial, sysname, syslanguage
    )

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": "OK", "metrics": {}, "details": ""}
    }
