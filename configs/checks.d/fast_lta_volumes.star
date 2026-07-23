# Module-level constants (no imports, no try/except)
DEFAULT_WARN = 80.0
DEFAULT_CRIT = 90.0
DEFAULT_INODE_WARN = 80.0
DEFAULT_INODE_CRIT = 90.0

def main(ctx, params):
    # Discovery mode: enumerate all volumes
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.27417.5.1.1.2"
        ], mutates=False)
        if res.rc != 0:
            fail("snmpwalk failed for fast_lta_volumes: " + res.stderr)

        # Extract volume names from SNMP output
        # Format: .1.3.6.1.4.1.27417.5.1.1.2.<idx> = STRING: "<volname>"
        volumes = []
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            # Split once on '=' to separate OID from value
            parts = line.split("=", 1)
            if len(parts) != 2:
                continue
            value_part = parts[1].strip()
            # Extract string value (remove quotes)
            if value_part.startswith('"') and value_part.endswith('"'):
                volname = value_part[1:-1]
            else:
                # Fallback: use raw value if not quoted
                volname = value_part
            volumes.append(volname)

        discovery_items = []
        for volname in volumes:
            discovery_items.append({
                "item": volname,
                "params": {
                    "levels": (DEFAULT_WARN, DEFAULT_CRIT),
                    "levels_low": (None, None),
                    "trend_range": 24,
                    "trend_perfdata": True
                },
                "metrics": ["used_percent"]
            })

        return {
            "changed": False,
            "msg": "discovered %d volumes" % len(volumes),
            "data": {"discovery": discovery_items}
        }

    # Check mode: evaluate one volume
    item = params.get("item", "")
    # Get thresholds from params (Checkmk defaults for filesystem checks)
    levels = params.get("levels", (DEFAULT_WARN, DEFAULT_CRIT))
    warn, crit = levels if isinstance(levels, (list, tuple)) and len(levels) >= 2 else (DEFAULT_WARN, DEFAULT_CRIT)

    # Fetch both volume quota and used values via snmpget (OIDs .2 and .11)
    # We need to get both values for the specific item (volume name index)
    # First get the index for this volume name
    res_idx = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.27417.5.1.1.2"
    ], mutates=False)
    if res_idx.rc != 0:
        return {
            "changed": False,
            "msg": "volume %s: SNMP fetch failed" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Find the index for the volume name
    vol_idx = -1
    for line in res_idx.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        value_part = parts[1].strip()
        # Extract string value (remove quotes)
        if value_part.startswith('"') and value_part.endswith('"'):
            volname = value_part[1:-1]
        else:
            volname = value_part

        if volname == item:
            # Extract the last number from the OID (e.g., ".1.3.6.1.4.1.27417.5.1.1.2.5" -> "5")
            oid = parts[0].strip()
            if "." in oid:
                vol_idx = oid.rsplit(".", 1)[1]
            break

    if vol_idx == -1:
        return {
            "changed": False,
            "msg": "volume %s: not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Now fetch quota and used values for this index
    res_quota = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.27417.5.1.1.9.%s" % vol_idx
    ], mutates=False)
    res_used = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.27417.5.1.1.11.%s" % vol_idx
    ], mutates=False)

    if res_quota.rc != 0 or res_used.rc != 0:
        return {
            "changed": False,
            "msg": "volume %s: SNMP fetch failed" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse quota and used values
    def parse_snmp_value(line):
        parts = line.strip().split("=", 1)
        if len(parts) != 2:
            return None
        value_part = parts[1].strip()
        # Extract number (remove trailing characters if needed)
        # Common formats: "INTEGER: 1234567890", "Gauge32: 1234567890", "1234567890"
        if ":" in value_part:
            value_part = value_part.split(":", 1)[1].strip()
        # Remove any remaining non-digit characters except minus
        clean_value = ""
        for c in value_part:
            if c.isdigit() or (c == "-" and not clean_value):
                clean_value += c
        return int(clean_value) if clean_value else None

    quota_bytes = parse_snmp_value(res_quota.stdout)
    used_bytes = parse_snmp_value(res_used.stdout)

    if quota_bytes == None or used_bytes == None or quota_bytes <= 0:
        return {
            "changed": False,
            "msg": "volume %s: invalid data" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Calculate values in MB (same as original parse_fast_lta_volumes)
    quota_mb = float(quota_bytes) / 1048576.0
    free_mb = float(quota_bytes - used_bytes) / 1048576.0
    used_mb = float(used_bytes) / 1048576.0

    # Calculate used_percent
    used_percent = (float(used_bytes) / float(quota_bytes)) * 100.0

    # Determine state based on thresholds (upper levels)
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"
    else:
        state = "OK"

    # Build message (Checkmk-style: "Size: 1.2 MB, Age: 5 m")
    msg = "Size: %f MB, Used: %f MB (%f%%)" % (quota_mb, used_mb, used_percent)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"used_percent": used_percent},
            "details": ""
        }
    }
