def main(ctx, params):
    # Discovery mode: yield one service (single-service check)
    if params.get("_discover"):
        # Probe SNMP: base OID .1.3.6.1.4.1.2620.1.6, OIDs [2,3,101,103]
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.2620.1.6"
        ], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "discovery failed",
                "data": {"discovery": []}
            }

        # Parse SNMP output: we need .1.3.6.1.4.1.2620.1.6.2 (major), .1.3.6.1.4.1.2620.1.6.3 (minor),
        # .1.3.6.1.4.1.2620.1.6.101 (code), .1.3.6.1.4.1.2620.1.6.103 (description)
        # Build a map from base OID suffix to value
        entries = {}
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            if "=" not in line:
                continue
            parts = line.split("=", 1)
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            val_part = parts[1].strip()
            # Extract suffix after base
            if oid_part.startswith(".1.3.6.1.4.1.2620.1.6."):
                suffix = oid_part[len(".1.3.6.1.4.1.2620.1.6."):]
                val = val_part
                # Strip type prefix if present (e.g. "STRING: " or "INTEGER: ")
                if val.startswith("STRING: ") or val.startswith("STRING:"):
                    val = val.split(":", 1)[1].strip().strip('"')
                elif val.startswith("INTEGER: ") or val.startswith("INTEGER:"):
                    val = val.split(":", 1)[1].strip()
                entries[suffix] = val

        # Check if we have all required values (at least one entry)
        if not entries:
            return {
                "changed": False,
                "msg": "discovery failed - no data",
                "data": {"discovery": []}
            }

        # Return one item for the single-service check
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
        }

    # Check mode: fetch SNMP and parse
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.2620.1.6"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SVN Status: SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse entries: build a map from suffix to value
    entries = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        val_part = parts[1].strip()
        if oid_part.startswith(".1.3.6.1.4.1.2620.1.6."):
            suffix = oid_part[len(".1.3.6.1.4.1.2620.1.6."):]
            val = val_part
            # Strip type prefix
            if val.startswith("STRING: ") or val.startswith("STRING:"):
                val = val.split(":", 1)[1].strip().strip('"')
            elif val.startswith("INTEGER: ") or val.startswith("INTEGER:"):
                val = val.split(":", 1)[1].strip()
            entries[suffix] = val

    # Require the 4 OIDs: 2 (major), 3 (minor), 101 (code), 103 (description)
    if not entries or "2" not in entries or "3" not in entries or "101" not in entries or "103" not in entries:
        return {
            "changed": False,
            "msg": "SVN Status: missing SNMP data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    major = entries["2"]
    minor = entries["3"]
    code = entries["101"]
    description = entries["103"]

    # Handle empty or missing code
    if code == "" or not code.isdigit():
        return {
            "changed": False,
            "msg": "SVN Status: OK (v%s.%s)" % (major, minor),
            "data": {"state": "OK", "metrics": {}, "details": ""}
        }

    code_int = int(code)
    if code_int != 0:
        summary = description if description else "Error code %s (v%s.%s)" % (code, major, minor)
        return {
            "changed": False,
            "msg": "SVN Status: " + summary,
            "data": {"state": "CRIT", "metrics": {}, "details": ""}
        }

    return {
        "changed": False,
        "msg": "SVN Status: OK (v%s.%s)" % (major, minor),
        "data": {"state": "OK", "metrics": {}, "details": ""}
    }
