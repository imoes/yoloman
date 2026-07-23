# ===== Starlark check module: emc_datadomain_fans =====

# SNMP OIDs for the FAN section
FANS_BASE_OID = ".1.3.6.1.4.1.19746.1.1.3.1.1.1"
FANS_OID_INDEX = FANS_BASE_OID + ".1"
FANS_OID_NAME = FANS_BASE_OID + ".2"
FANS_OID_DESCR = FANS_BASE_OID + ".4"
FANS_OID_LEVEL = FANS_BASE_OID + ".5"
FANS_OID_STATE = FANS_BASE_OID + ".6"

# State mapping (from Checkmk source)
STATE_TABLE = {
    "0": ("notfound", "WARN"),
    "1": ("OK", "OK"),
    "2": ("Fail", "CRIT"),
}

# Fan level mapping (from Checkmk source)
FAN_LEVEL = {
    "0": "Unknown",
    "1": "Low",
    "2": "Medium",
    "3": "High",
}

# Detect OID for Data Domain (DETECT_DATADOMAIN)
SYSDESCR_OID = ".1.3.6.1.2.1.1.1.0"


def _get_sysdescr(ctx, params):
    # Get system description to detect Data Domain
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"), SYSDESCR_OID], mutates=False)
    if res.rc != 0 or not res.stdout:
        return ""
    # Output format: .1.3.6.1.2.1.1.1.0 = STRING: "..."
    parts = res.stdout.strip().split(" = ", 1)
    if len(parts) < 2:
        return ""
    return parts[1].strip().strip('"')


def _walk_section(ctx, params, base_oid):
    # Walk a single OID field and return list of values
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"), base_oid], mutates=False)
    if res.rc != 0 or not res.stdout:
        return []
    results = []
    for line in res.stdout.splitlines():
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) < 2:
            continue
        # Extract value after type indicator (e.g., "STRING:", "INTEGER:", etc.)
        value_part = parts[1].strip()
        if ":" in value_part:
            value = value_part.split(":", 1)[1].strip().strip('"')
        else:
            value = value_part
        results.append(value)
    return results


def main(ctx, params):
    # === DISCOVERY MODE ===
    if params.get("_discover"):
        # Detect Data Domain first
        sysdescr = _get_sysdescr(ctx, params)
        if not sysdescr.startswith("Data Domain OS"):
            return {"changed": False, "msg": "discovered 0 items (not Data Domain)",
                    "data": {"discovery": []}}

        # Fetch all FAN section fields
        indices = _walk_section(ctx, params, FANS_OID_INDEX)
        names = _walk_section(ctx, params, FANS_OID_NAME)
        # We don't need descr/level/state for discovery, just items

        items = []
        for i in range(len(indices)):
            if i < len(names):
                item = indices[i] + "-" + names[i]
                items.append({"item": item, "params": {}, "metrics": []})

        return {"changed": False, "msg": "discovered %d FANs" % len(items),
                "data": {"discovery": items}}

    # === CHECK MODE ===
    item = params.get("item", "")
    
    # Detect Data Domain first
    sysdescr = _get_sysdescr(ctx, params)
    if not sysdescr.startswith("Data Domain OS"):
        return {"changed": False, "msg": "not Data Domain device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch all FAN section fields
    indices = _walk_section(ctx, params, FANS_OID_INDEX)
    names = _walk_section(ctx, params, FANS_OID_NAME)
    descs = _walk_section(ctx, params, FANS_OID_DESCR)
    levels = _walk_section(ctx, params, FANS_OID_LEVEL)
    states = _walk_section(ctx, params, FANS_OID_STATE)

    # Find matching FAN item
    found = False
    for i in range(len(indices)):
        if i < len(names):
            fan_item = indices[i] + "-" + names[i]
            if fan_item == item:
                found = True
                dev_descr = descs[i] if i < len(descs) else ""
                dev_level = levels[i] if i < len(levels) else "0"
                dev_state = states[i] if i < len(states) else "0"

                state_str, state_rc = STATE_TABLE.get(dev_state, ("Unknown", "UNKNOWN"))
                level_str = FAN_LEVEL.get(dev_level, "Unknown")

                infotext = dev_descr + " " + state_str + " RPM " + level_str
                return {"changed": False, "msg": infotext,
                        "data": {"state": state_rc, "metrics": {}, "details": ""}}

    if not found:
        return {"changed": False, "msg": "FAN item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
