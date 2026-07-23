# Module: entersekt_ecerterrors
# Checkmk: entersekt_ecerterrors
# Read-only Starlark translation of the SNMP-based check

METRIC_NAME = "Errors"

def main(ctx, params):
    # Discovery mode: yield one service
    if params.get("_discover"):
        # Probe the SNMP section by walking the base OID
        # Checkmk detect: all_of(contains(sysDescr, "linux"), exists(.1.3.6.1.4.1.38235.2.3.1.0))
        # We'll just try to read OID .1.3.6.1.4.1.38235.2.3.1.0 (server running)
        # If present, the check applies.
        res = ctx.run([
            "snmpget", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), ".1.3.6.1.4.1.38235.2.3.1.0"
        ], mutates=False)
        # If the OID is missing or command fails, discovery yields nothing
        if res.rc != 0 or "No Such Instance" in res.stdout or "No Such Object" in res.stdout:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 items",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": [METRIC_NAME]}]}}

    # Check mode
    # Fetch all needed SNMP OIDs from the entersekt tree
    # OIDs: .1.3.6.1.4.1.38235.2.3.1.0 (server running), .1.3.6.1.4.1.38235.2.3.3.1.0 (emr errors),
    #       .1.3.6.1.4.1.38235.2.3.5.1.0 (ecert errors), .1.3.6.1.4.1.38235.2.3.7.1.0 (soap errors),
    #       .1.3.6.1.4.1.38235.2.3.17.1.0 (cert days to expiry)
    # For this check we only need the ecert errors OID (section[0][2])
    oids = [
        ".1.3.6.1.4.1.38235.2.3.1.0",
        ".1.3.6.1.4.1.38235.2.3.3.1.0",
        ".1.3.6.1.4.1.38235.2.3.5.1.0",
        ".1.3.6.1.4.1.38235.2.3.7.1.0",
        ".1.3.6.1.4.1.38235.2.3.17.1.0"
    ]
    cmd = ["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
           params.get("host", "localhost")] + oids
    res = ctx.run(cmd, mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse snmpwalk output: lines like "OID = TYPE: value"
    lines = res.stdout.split("\n")
    values = {}
    for line in lines:
        if not line.strip():
            continue
        # Split at first "="
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        val_part = parts[1].strip()
        # Extract value after ": "
        if ": " in val_part:
            val = val_part.split(": ", 1)[1].strip()
        else:
            val = val_part
        # Map OID suffixes to indices for section[0][idx]
        if oid.endswith(".1.0"):
            values[0] = val
        elif oid.endswith(".3.1.0"):
            values[1] = val
        elif oid.endswith(".5.1.0"):
            values[2] = val
        elif oid.endswith(".7.1.0"):
            values[3] = val
        elif oid.endswith(".17.1.0"):
            values[4] = val

    if 2 not in values:
        return {"changed": False, "msg": "ECert Errors OID not found in SNMP data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Extract errors count from section[0][2]
    errors_str = values[2]
    if not errors_str.isdigit():
        return {"changed": False, "msg": "ECert Errors value is not a number: " + errors_str,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    errors = int(errors_str)

    # Thresholds
    levels = params.get("levels", (100, 200))
    warn = levels[0]
    crit = levels[1]

    # Determine state (upper levels)
    state = "CRIT" if errors >= crit else ("WARN" if errors >= warn else "OK")

    return {"changed": False, "msg": "Number of errors is %d" % errors,
            "data": {"state": state, "metrics": {METRIC_NAME: errors}, "details": ""}}
