def main(ctx, params):
    # Discovery mode: enumerate all IN voltage phases with value > 0
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.2.1.33.1.3.3.1"
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, base_oid
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)

        # Parse SNMP output: OIDEnd gives item, .3 gives voltage
        # We'll process lines like:
        # .1.3.6.1.2.1.33.1.3.3.1.1.<end>.3 = INTEGER: 230
        # The item is the <end> part (e.g., "1", "2", "3")
        items = {}
        for line in res.stdout.splitlines():
            stripped = line.strip()
            if stripped == "":
                continue
            # Split into OID and value
            parts = stripped.split(" = ")
            if len(parts) != 2:
                continue
            oid = parts[0]
            value_part = parts[1]
            # Extract value (e.g., "INTEGER: 230" or "INTEGER 230")
            if value_part.startswith("INTEGER: "):
                value_str = value_part[9:]
            elif value_part.startswith("INTEGER "):
                value_str = value_part[8:]
            else:
                continue
            # Skip if value is empty
            value_str = value_str.strip()
            if value_str == "":
                continue
            # Parse integer value
            if not value_str.isdigit():
                continue
            value = int(value_str)
            # Only include items with value > 0
            if value <= 0:
                continue
            # Extract item (the part after the base OID)
            # Base OID is ".1.3.6.1.2.1.33.1.3.3.1.1."
            item_oid_prefix = base_oid + ".1."
            if oid.startswith(item_oid_prefix):
                item = oid[len(item_oid_prefix):].strip()
                # Skip if item is empty
                if item == "":
                    continue
                # Avoid duplicates (prefer first)
                if item not in items:
                    items[item] = value

        discovery = []
        for item, value in items.items():
            # Checkmk defaults: levels_lower = (210.0, 180.0)
            discovery.append({
                "item": item,
                "params": {"levels_lower": [210.0, 180.0]},
                "metrics": ["in_voltage"]
            })
        return {
            "changed": False,
            "msg": "discovered %d IN voltage phases" % len(discovery),
            "data": {"discovery": discovery}
        }

    # Check mode: examine one specific item (phase)
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.2.1.33.1.3.3.1"

    # Build the specific OID for the item: base_oid + ".1." + item + ".3"
    target_oid = base_oid + ".1." + item + ".3"
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host, target_oid
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP get failed for item " + item + ": " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse single-line output: e.g., ".1.3.6.1.2.1.33.1.3.3.1.1.2.3 = INTEGER: 230"
    stripped = res.stdout.strip()
    if stripped == "":
        return {
            "changed": False,
            "msg": "no data for item " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract value from line
    parts = stripped.split(" = ")
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "unexpected SNMP output for item " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    value_part = parts[1]
    # Extract integer value
    if value_part.startswith("INTEGER: "):
        value_str = value_part[9:]
    elif value_part.startswith("INTEGER "):
        value_str = value_part[8:]
    else:
        return {
            "changed": False,
            "msg": "unexpected SNMP value format for item " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    value_str = value_str.strip()
    if not value_str.isdigit():
        return {
            "changed": False,
            "msg": "non-numeric value for item " + item + ": " + value_str,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    value = int(value_str)

    # Extract thresholds: Checkmk default levels_lower = (210.0, 180.0)
    levels_lower = params.get("levels_lower", [210.0, 180.0])
    if type(levels_lower) == "dict":
        # Handle legacy mapping format (shouldn't happen in our translated context)
        levels_lower = levels_lower.get("levels_lower", [210.0, 180.0])

    lower_warn = levels_lower[0]
    lower_crit = levels_lower[1]

    # Determine state based on lower thresholds
    if value <= lower_crit:
        state = "CRIT"
        summary = "IN voltage: %d V (critical)" % value
    elif value <= lower_warn:
        state = "WARN"
        summary = "IN voltage: %d V (warning)" % value
    else:
        state = "OK"
        summary = "IN voltage: %d V" % value

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"in_voltage": value},
            "details": ""
        }
    }