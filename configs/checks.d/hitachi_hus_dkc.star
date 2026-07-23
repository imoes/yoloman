# State mappings from SNMP value to (State enum name, description)
_HUS_MAP_STATES = {
    "0": ("UNKNOWN", "unknown"),
    "1": ("OK", "no error"),
    "2": ("CRIT", "acute"),
    "3": ("CRIT", "serious"),
    "4": ("WARN", "moderate"),
    "5": ("WARN", "service"),
}

# DKC labels in order of SNMP OIDs 1..9
_DKC_LABELS = ("Processor", "Internal Bus", "Cache", "Shared Memory", "Power Supply", "Battery", "Fan", "Environment")


def main(ctx, params):
    if params.get("_discover"):
        # Discover all DKC items by walking the base OID
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.116.5.11.4.1.1.6.1"
        ], mutates=False)
        if res.rc != 0:
            # Agent unreachable or SNMP error: report no items
            return {"changed": False, "msg": "discovered 0 DKC items",
                    "data": {"discovery": []}}
        # Parse snmpwalk output: each line is "OID = Type: Value"
        # Group lines by base OID (first 8 components after .1.3.6.1.4.1.116.5.11.4.1.1.6.1)
        lines = res.stdout.splitlines()
        # We need the base item (the first OID's numeric suffix) to identify the item.
        # Checkmk parses "1.3.6.1.4.1.116.5.11.4.1.1.6.1.x" where x is the item index.
        # We'll group by the last numeric component after the base.
        items_map = {}  # item_id (x) -> list of values
        for line in lines:
            line = line.strip()
            if not line:
                continue
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            oid_str = parts[0].strip()
            # Extract numeric suffix after base
            if not oid_str.startswith(".1.3.6.1.4.1.116.5.11.4.1.1.6.1."):
                continue
            suffix = oid_str[32:]  # len(".1.3.6.1.4.1.116.5.11.4.1.1.6.1.") = 32
            if not suffix.lstrip("0123456789").isdigit() and suffix.replace(".", "").isdigit():
                # Just get the numeric part before any dot
                oid_parts = suffix.split(".")
                if not oid_parts:
                    continue
                item_id = oid_parts[0]
            else:
                # Fallback: take first number sequence
                # No re allowed — rewrite without regex
                # We'll just split by dot and take first
                item_id = suffix.split(".")[0] if "." in suffix else suffix
                if not item_id:
                    continue
            value_str = parts[1].strip()
            # Extract the value (after colon)
            if ":" in value_str:
                value = value_str.split(":", 1)[1].strip()
            else:
                continue
            if item_id not in items_map:
                items_map[item_id] = []
            items_map[item_id].append(value)
        # Build discovery list: each item_id becomes an item
        discovery_items = []
        for item_id in sorted(items_map.keys(), key=lambda x: int(x)):
            values = items_map[item_id]
            # Expect 8 values (one per label), but we can still report even if missing
            if len(values) < 8:
                # Still discover but with incomplete data — check will report UNKNOWN
                pass
            discovery_items.append({
                "item": item_id,
                "params": {},
                "metrics": []
            })
        return {"changed": False, "msg": "discovered %d DKC items" % len(discovery_items),
                "data": {"discovery": discovery_items}}

    # CHECK MODE
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    # Fetch only the OIDs for the requested item
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host,
        ".1.3.6.1.4.1.116.5.11.4.1.1.6.1." + item + ".1",
        ".1.3.6.1.4.1.116.5.11.4.1.1.6.1." + item + ".2",
        ".1.3.6.1.4.1.116.5.11.4.1.1.6.1." + item + ".3",
        ".1.3.6.1.4.1.116.5.11.4.1.1.6.1." + item + ".4",
        ".1.3.6.1.4.1.116.5.11.4.1.1.6.1." + item + ".5",
        ".1.3.6.1.4.1.116.5.11.4.1.1.6.1." + item + ".6",
        ".1.3.6.1.4.1.116.5.11.4.1.1.6.1." + item + ".7",
        ".1.3.6.1.4.1.116.5.11.4.1.1.6.1." + item + ".8"
    ], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no data for DKC item %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    # Parse each line: "OID = Type: Value"
    values = []
    lines = res.stdout.splitlines()
    for line in lines:
        if " = " in line:
            val_str = line.split(" = ", 1)[1].strip()
            # Value is after the colon
            if ":" in val_str:
                v = val_str.split(":", 1)[1].strip()
                values.append(v)
            else:
                return {"changed": False, "msg": "malformed SNMP response",
                        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if len(values) < 8:
        return {"changed": False, "msg": "incomplete data for DKC item %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    # Determine worst state across properties
    worst_state = "OK"
    details_parts = []
    for i in range(len(_DKC_LABELS)):
        label = _DKC_LABELS[i]
        v = values[i]
        if v in _HUS_MAP_STATES:
            state_name, desc = _HUS_MAP_STATES[v]
        else:
            state_name = "UNKNOWN"
            desc = "unknown"
        details_parts.append("%s: %s" % (label, desc))
        if state_name == "CRIT":
            worst_state = "CRIT"
        elif state_name == "WARN" and worst_state != "CRIT":
            worst_state = "WARN"
        elif state_name == "UNKNOWN" and worst_state == "OK":
            worst_state = "UNKNOWN"
    return {
        "changed": False,
        "msg": "%s" % worst_state,
        "data": {
            "state": worst_state,
            "metrics": {},
            "details": "; ".join(details_parts)
        }
    }