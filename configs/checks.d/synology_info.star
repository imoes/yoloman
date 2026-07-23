def main(ctx, params):
    # Discovery mode: synology_info always yields one service with item ""
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    # Check mode: query Synology SNMP OIDs
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.6574.1.5"

    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_oid + ".1", base_oid + ".2", base_oid + ".3"
    ], mutates=False)

    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "SNMP query failed or empty output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse snmpwalk output lines: "<OID> = STRING: <value>"
    model = ""
    serialnumber = ""
    os_version = ""

    for line in res.stdout.splitlines():
        # Split on first "="
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()

        # Determine which OID this is by trailing number
        if oid_part.endswith(".1"):
            # Strip type prefix ("STRING: " or similar) and quotes
            val = value_part.lstrip("STRING: ").strip('"').strip("'")
            model = val
        elif oid_part.endswith(".2"):
            val = value_part.lstrip("STRING: ").strip('"').strip("'")
            serialnumber = val
        elif oid_part.endswith(".3"):
            val = value_part.lstrip("STRING: ").strip('"').strip("'")
            os_version = val

    # If any critical field is missing, report UNKNOWN
    if not model or not serialnumber or not os_version:
        return {
            "changed": False,
            "msg": "missing data: model=%s, serial=%s, os=%s" % (model, serialnumber, os_version),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    summary = "Model: %s, S/N: %s, OS Version: %s" % (model, serialnumber, os_version)
    return {
        "changed": False,
        "msg": summary,
        "data": {"state": "OK", "metrics": {}, "details": ""},
    }