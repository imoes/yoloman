def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On",
            host,
            ".1.3.6.1.4.1.3854.2.3.4.1"
        ], mutates=False)

        # Parse SNMP output: base OID .1.3.6.1.4.1.3854.2.3.4.1 with sub-oids 2,6,46,48,8
        # OID mapping:
        #   .2  = description
        #   .6  = state
        #   .46 = online
        #   .48 = critical_desc
        #   .8  = normal_desc
        # Format per line: "OID = STRING: value"
        discovery_items = []
        lines = res.stdout.splitlines() if res.stdout else []

        # Build a map of description to online status
        description_online_map = {}
        description_desc_map = {}

        for line in lines:
            parts = line.strip().split(" = ", 2)
            if len(parts) != 2:
                continue
            oid, value = parts
            # Strip trailing .index from OID (e.g., .1.3.6.1.4.1.3854.2.3.4.1.2.1 -> .1.3.6.1.4.1.3854.2.3.4.1.2)
            base_oid = oid.rsplit(".", 1)[0]
            # Extract value type and content (e.g., "STRING: Diesel1 Generatorbetrieb")
            if ": " in value:
                value = value.split(": ", 1)[1].strip().strip('"')

            # Map index-specific OIDs back to base
            if base_oid.endswith(".2"):
                # Description
                index = oid.rsplit(".", 1)[1]
                description_desc_map[index] = value
            elif base_oid.endswith(".46"):
                # Online status
                index = oid.rsplit(".", 1)[1]
                description_online_map[index] = value

        # Group by index and create discovery entries
        seen = {}
        for idx in description_desc_map:
            online = description_online_map.get(idx, "2")
            if online == "1":
                item = description_desc_map[idx]
                if item not in seen:
                    seen[item] = True
                    discovery_items.append({
                        "item": item,
                        "params": {},
                        "metrics": []
                    })

        return {
            "changed": False,
            "msg": "discovered %d dry contact%s" % (len(discovery_items), "s" if len(discovery_items) != 1 else ""),
            "data": {"discovery": discovery_items}
        }

    # Check mode
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "item is required for check mode",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On",
        host,
        ".1.3.6.1.4.1.3854.2.3.4.1"
    ], mutates=False)

    lines = res.stdout.splitlines() if res.stdout else []

    # Build lookup tables for current item
    description = ""
    state = ""
    online = "2"
    crit_desc = "Drycontact on Error"
    normal_desc = "Drycontact OK"

    # Helper to parse OID values
    for line in lines:
        if not line.strip():
            continue
        parts = line.strip().split(" = ", 2)
        if len(parts) != 2:
            continue
        oid, value = parts
        # Extract base OID and index
        base_oid = oid.rsplit(".", 1)[0]
        index = oid.rsplit(".", 1)[1]

        # Only process OIDs for the same instance (index)
        # We need to find the index corresponding to the item description
        # Since snmpwalk returns all instances, we'll parse and match by description first
        if base_oid.endswith(".2"):
            desc_val = value.split(": ", 1)[1].strip().strip('"') if ": " in value else ""
            if desc_val == item:
                # Found matching index
                break

    # Re-scan to extract all fields for the matching index
    # We'll iterate and track when we've found the correct index
    found_idx = None
    for line in lines:
        if not line.strip():
            continue
        parts = line.strip().split(" = ", 2)
        if len(parts) != 2:
            continue
        oid, value = parts
        base_oid = oid.rsplit(".", 1)[0]

        # Extract value content
        if ": " in value:
            value = value.split(": ", 1)[1].strip().strip('"')

        # Match by description first
        if base_oid.endswith(".2"):
            if value == item:
                found_idx = oid.rsplit(".", 1)[1]
                description = value
            else:
                # Skip other items
                continue

        if found_idx:
            # Get current line's value for this index
            current_idx = oid.rsplit(".", 1)[1]
            if current_idx != found_idx:
                continue

            if base_oid.endswith(".2"):
                description = value
            elif base_oid.endswith(".6"):
                state = value
            elif base_oid.endswith(".46"):
                online = value
            elif base_oid.endswith(".48"):
                crit_desc = value
            elif base_oid.endswith(".8"):
                normal_desc = value

    # If we didn't find the item in the first pass, try to match directly
    if not found_idx:
        for line in lines:
            parts = line.strip().split(" = ", 2)
            if len(parts) != 2:
                continue
            oid, value = parts
            base_oid = oid.rsplit(".", 1)[0]

            if ": " in value:
                value = value.split(": ", 1)[1].strip().strip('"')

            if base_oid.endswith(".2") and value == item:
                # Found matching index
                found_idx = oid.rsplit(".", 1)[1]
                break

        # Re-scan for this index
        for line in lines:
            if not line.strip():
                continue
            parts = line.strip().split(" = ", 2)
            if len(parts) != 2:
                continue
            oid, value = parts
            base_oid = oid.rsplit(".", 1)[0]
            current_idx = oid.rsplit(".", 1)[1]

            if current_idx != found_idx:
                continue

            if ": " in value:
                value = value.split(": ", 1)[1].strip().strip('"')

            if base_oid.endswith(".2"):
                description = value
            elif base_oid.endswith(".6"):
                state = value
            elif base_oid.endswith(".46"):
                online = value
            elif base_oid.endswith(".48"):
                crit_desc = value
            elif base_oid.endswith(".8"):
                normal_desc = value

    # State logic per Checkmk source
    # Drycontact states (per SPAGENT-MIB)
    states = {
        "1": (2, "no status"),
        "7": (2, "sensor error"),
        "8": (2, "output low"),
        "9": (2, "output high"),
    }

    if online != "1":
        return {
            "changed": False,
            "msg": "sensor is offline",
            "data": {"state": "CRIT", "metrics": {}, "details": ""}
        }

    if state == "2":
        return {
            "changed": False,
            "msg": normal_desc,
            "data": {"state": "OK", "metrics": {}, "details": ""}
        }

    if state in ["4", "6"]:
        return {
            "changed": False,
            "msg": crit_desc,
            "data": {"state": "CRIT", "metrics": {}, "details": ""}
        }

    if state in states:
        state_num, infotext = states[state]
        state_name = "CRIT" if state_num == 2 else ("WARN" if state_num == 1 else "OK")
        return {
            "changed": False,
            "msg": infotext,
            "data": {"state": state_name, "metrics": {}, "details": ""}
        }

    # Fallback: unknown state
    return {
        "changed": False,
        "msg": "unknown state: " + str(state),
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
    }
