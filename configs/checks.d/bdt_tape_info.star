# Top-level constants: SNMP OIDs and metric mappings
_BDT_TAPE_BASE_OID = ".1.3.6.1.4.1.20884.10893.2.101.1"
_BDT_TAPE_DETECT_OID = ".1.3.6.1.2.1.1.2.0"
_BDT_TAPE_DETECT_VALUE = ".1.3.6.1.4.1.20884.10893.2.101"
_FIELDS = ["Name", "Description", "Vendor", "Agent Version"]

def main(ctx, params):
    # Discovery mode: always yield one service (per spec, discover_bdt_tape_info yields Service())
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": []
                    }
                ]
            }
        }

    # Check mode: fetch SNMP data for this single service (no per-item breakdown)
    # Build complete OIDs for the 4 fields: base + index (1..4)
    oids = [
        _BDT_TAPE_BASE_OID + "." + str(i)
        for i in range(1, 5)
    ]

    # Build snmpwalk command for all required OIDs
    # Use default community if not provided
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    argv = ["snmpwalk", "-v2c", "-c", community, "-On", host] + oids
    res = ctx.run(argv, mutates=False)

    # Parse SNMP output: lines like "OID = STRING: value" or "OID = INTEGER: value"
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Map OID suffixes to field names (last component of OID)
    # e.g., ".1.3.6.1.4.1.20884.10893.2.101.1.1" -> suffix "1" -> field "Name"
    values = {}
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        # Split on first '=' to separate OID from value
        eq_pos = stripped.find("=")
        if eq_pos == -1:
            continue
        oid_part = stripped[:eq_pos].strip()
        val_part = stripped[eq_pos + 1:].strip()

        # Extract last numeric component of OID (the index)
        # Handle both full OIDs and partial matches
        oid_tokens = oid_part.split(".")
        if len(oid_tokens) == 0:
            continue
        last_token = oid_tokens[-1]
        if not last_token.isdigit():
            continue
        index = int(last_token)
        if (index >= 1) and (index <= 4):
            field = _FIELDS[index - 1]
            # Strip quotes if present (SNMP STRINGs often appear as quoted strings)
            # Common formats: "value", "value", 'value', value
            # Remove surrounding double quotes if present
            if val_part.startswith('"') and val_part.endswith('"'):
                val_part = val_part[1:-1]
            elif val_part.startswith("'") and val_part.endswith("'"):
                val_part = val_part[1:-1]
            values[field] = val_part

    # Build result: iterate over fields and produce summary line per field
    summaries = []
    for field in _FIELDS:
        value = values.get(field, "")
        summaries.append("%s: %s" % (field, value))

    # Always return OK state since checkmk code yields State.OK for all fields
    return {
        "changed": False,
        "msg": ", ".join(summaries),
        "data": {
            "state": "OK",
            "metrics": {},
            "details": ""
        }
    }
