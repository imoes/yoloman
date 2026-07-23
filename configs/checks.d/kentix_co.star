def main(ctx, params):
    # Discover mode: yield a single-service entry with empty item and default params
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {"levels_ppm": [10, 25]},
                        "metrics": ["parts_per_million"]
                    }
                ]
            },
        }

    # Check mode: retrieve CO concentration via SNMP
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    # Base OID from the source: .1.3.6.1.4.1.37954, then .2.1.4.1 or .3.1.3.1
    # We try both OIDs; the first successful non-zero value wins.
    oids = [".1.3.6.1.4.1.37954.2.1.4.1", ".1.3.6.1.4.1.37954.3.1.3.1"]
    co_value = None

    for oid in oids:
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, oid], mutates=False)
        if res.rc != 0:
            continue
        # Format: "<oid> = STRING: \"<value>\"" or similar
        line = res.stdout.strip()
        # Skip empty output
        if not line:
            continue
        # Try to extract the numeric value from the last part
        # Examples: ".1.3.6.1.4.1.37954.2.1.4.1 = STRING: \"0\""
        parts = line.split()
        if len(parts) < 3:
            continue
        # Get last part after '='
        raw = line.split("=", 1)[-1].strip()
        # Strip quotes if present
        if raw.startswith('"') and raw.endswith('"'):
            raw = raw[1:-1]
        # Try to parse as int
        if raw.isdigit() or (raw.startswith("-") and raw[1:].isdigit()):
            val = int(raw)
            co_value = val
            break
        # Skip float attempt (no float.isdigit() in Starlark)

    # If no value found, return UNKNOWN state
    if co_value == None:
        return {
            "changed": False,
            "msg": "could not retrieve CO concentration",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Extract thresholds with Checkmk defaults
    levels = params.get("levels_ppm", [10, 25])
    warn = levels[0]
    crit = levels[1]

    # Determine state: warn if >= warn, crit if >= crit
    state = "CRIT" if co_value >= crit else ("WARN" if co_value >= warn else "OK")

    return {
        "changed": False,
        "msg": "CO concentration: %d ppm" % co_value,
        "data": {
            "state": state,
            "metrics": {"parts_per_million": co_value},
            "details": ""
        }
    }