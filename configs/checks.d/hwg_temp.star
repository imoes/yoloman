# hwg_temp Starlark check module — temperature sensors via SNMP
# Read-only: no mutations, never changed=True

# OID base and fields (from Checkmk plugin)
# base = .1.3.6.1.4.1.21796.4.1.3.1
# oids = ["1", "2", "3", "4", "7"]
# index, descr, dev_status, current, unit
OID_BASE = ".1.3.6.1.4.1.21796.4.1.3.1"
OID_DESCR = OID_BASE + ".2"
OID_STATUS = OID_BASE + ".3"
OID_CURRENT = OID_BASE + ".4"
OID_UNIT = OID_BASE + ".7"

# Device state mapping (same as Python)
MAP_DEV_STATES = {
    "0": "invalid",
    "1": "normal",
    "2": "out of range low",
    "3": "out of range high",
    "4": "alarm low",
    "5": "alarm high",
}

# Unit mapping (same as Python)
MAP_UNITS = {"1": "c", "2": "f", "3": "k", "4": "%"}

# Default levels (same as Checkmk)
HWG_TEMP_DEFAULTLEVELS = {"levels": (30.0, 35.0)}

# Helper to convert SNMP output type:value lines into a dict {index: {field: value}}
def _walk_snmp(ctx, host, community, base_oid):
    # We need the full OID set: base + suffixes
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    out = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        full_oid = parts[0].strip()
        val_part = parts[1].strip()
        if not full_oid.startswith(base_oid + "."):
            continue
        suffix = full_oid[len(base_oid) + 1:]
        if "." in suffix:
            continue  # skip sub-objects
        # Parse value type
        if ": " in val_part:
            type_val = val_part.split(": ", 1)
            if len(type_val) == 2:
                val = type_val[1].strip().strip('"')
            else:
                val = val_part.strip().strip('"')
        else:
            val = val_part.strip().strip('"')
        out[suffix] = val
    return out

def _decode_state(status):
    return MAP_DEV_STATES.get(status, "invalid")

def _decode_unit(unit):
    return MAP_UNITS.get(unit, "")

def main(ctx, params):
    # SNMP parameters
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Discovery mode
    if params.get("_discover"):
        # Fetch all fields at once
        index_map = _walk_snmp(ctx, host, community, OID_BASE + ".1")
        descr_map = _walk_snmp(ctx, host, community, OID_DESCR)
        status_map = _walk_snmp(ctx, host, community, OID_STATUS)
        current_map = _walk_snmp(ctx, host, community, OID_CURRENT)
        unit_map = _walk_snmp(ctx, host, community, OID_UNIT)

        # Combine per index
        items = []
        for idx in index_map.keys():
            status = status_map.get(idx, "0")
            state_name = _decode_state(status)
            if state_name == "invalid" or state_name == "":
                continue
            curr = current_map.get(idx, "")
            if curr == "":
                continue
            # Only temperature sensors (unit != "%")
            unit = unit_map.get(idx, "")
            if _decode_unit(unit) == "%":
                continue

            # Suggested params
            items.append({
                "item": idx,
                "params": {"levels": HWG_TEMP_DEFAULTLEVELS["levels"]},
                "metrics": ["temp"]
            })

        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(items),
            "data": {"discovery": items}
        }

    # Check mode
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Fetch needed fields
    index_map = _walk_snmp(ctx, host, community, OID_BASE + ".1")
    if item not in index_map:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    status_map = _walk_snmp(ctx, host, community, OID_STATUS)
    current_map = _walk_snmp(ctx, host, community, OID_CURRENT)
    unit_map = _walk_snmp(ctx, host, community, OID_DESCR)
    descr_map = _walk_snmp(ctx, host, community, OID_DESCR)

    status = status_map.get(item, "0")
    state_name = _decode_state(status)
    state_readable = state_name

    # Determine state from status (same as READABLE_STATES)
    if state_name == "invalid":
        state = "UNKNOWN"
    elif state_name == "normal":
        state = "OK"
    else:
        state = "CRIT"

    # Get temperature value with guard instead of try/except
    curr = current_map.get(item, "")
    temp = float(curr) if curr != "" and curr.replace(".", "", 1).replace("-", "", 1).isdigit() else None

    if temp == None:
        return {
            "changed": False,
            "msg": "Status: " + state_readable,
            "data": {"state": state, "metrics": {}, "details": ""}
        }

    # Get unit and description
    unit = unit_map.get(item, "")
    unit_name = _decode_unit(unit)
    descr = descr_map.get(item, "")

    # Extract levels
    levels = params.get("levels", HWG_TEMP_DEFAULTLEVELS["levels"])
    warn = levels[0]
    crit = levels[1]

    # Determine state based on thresholds (same logic as check_temperature)
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"
    else:
        state = "OK"

    # Build summary
    summary = "Temperature: %f %s" % (temp, unit_name.upper() if unit_name else "")
    if state_readable != "normal":
        summary = summary + ", Status: " + state_readable

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"temp": temp},
            "details": "Description: " + descr + ", Status: " + state_readable
        }
    }