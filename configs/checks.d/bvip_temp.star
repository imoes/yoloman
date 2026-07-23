# ===== module-level constants =====
SNMP_BASE = ".1.3.6.1.4.1.3967.1.1.7.1"
DETECT_OID = ".1.3.6.1.2.1.1.1.0"
BVIP_NAMES = ["flexidome", "vip-x", "dinion", "autodome"]
DEFAULT_WARN = 50.0
DEFAULT_CRIT = 60.0


def _detect_bvip(ctx):
    # Detect BVIP device by reading system description
    res = ctx.run(["snmpget", "-v2c", "-c", "public", "-On", "localhost", DETECT_OID], mutates=False)
    if res.rc != 0:
        return False
    line = res.stdout.strip()
    if " = STRING: " in line:
        desc = line.split(" = STRING: ", 1)[1].strip('"')
    else:
        return False
    for name in BVIP_NAMES:
        if name in desc.lower():
            return True
    return False


def _walk_temp(ctx, community):
    # Walk the temperature OIDs: base + OIDEnd (item name) and OID 1 (value)
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", "localhost", SNMP_BASE], mutates=False)
    if res.rc != 0 or not res.stdout:
        return []
    items = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        # Format: <oid> = STRING: "<item_name>" or <oid>.1 = INTEGER: <value>
        eq_pos = line.find(" = ")
        if eq_pos == -1:
            continue
        oid = line[:eq_pos].strip()
        value_part = line[eq_pos+3:].strip()
        if value_part.startswith("STRING: "):
            # This is the item name line
            name = value_part[8:].strip('"')
            items.append((name, None))
        elif value_part.startswith("INTEGER: "):
            # This is the temperature value line (.1)
            val_str = value_part[9:].strip()
            if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
                temp = int(val_str)
                items.append((None, temp))
            else:
                continue
    # Reconstruct pairs: (item_name, temp_value) by aligning sequential entries
    pairs = []
    current_name = None
    for name, temp in items:
        if name != None:
            current_name = name
        elif temp != None and current_name != None:
            pairs.append((current_name, temp))
    return pairs


def main(ctx, params):
    if params.get("_discover"):
        # Detect BVIP device first
        community = params.get("community", "public")
        if not _detect_bvip(ctx):
            return {"changed": False, "msg": "not a BVIP device", "data": {"discovery": []}}

        # Walk temperatures
        items = _walk_temp(ctx, community)
        discovery = []
        for item_name, _ in items:
            discovery.append({
                "item": item_name,
                "params": {"warn": DEFAULT_WARN, "crit": DEFAULT_CRIT},
                "metrics": ["temp"]
            })
        return {"changed": False, "msg": "discovered %d temperature sensors" % len(discovery),
                "data": {"discovery": discovery}}

    # Normal check mode (non-discovery)
    item = params.get("item", "")
    community = params.get("community", "public")

    # Skip if not a BVIP device
    if not _detect_bvip(ctx):
        return {"changed": False, "msg": "not a BVIP device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Get temperature data
    temp_pairs = _walk_temp(ctx, community)
    temp = None
    for name, val in temp_pairs:
        if name == item:
            temp = val
            break

    # Check for missing item or data
    if temp == None:
        return {"changed": False, "msg": "temperature sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Convert temperature to degrees (value / 10)
    temp_c = float(temp) / 10.0

    # Read thresholds (Checkmk default: (50.0, 60.0))
    warn = params.get("warn", DEFAULT_WARN)
    crit = params.get("crit", DEFAULT_CRIT)

    # Determine state based on thresholds (upper levels)
    if temp_c >= crit:
        state = "CRIT"
    elif temp_c >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {"changed": False,
            "msg": "Temperature: %f C" % temp_c,
            "data": {
                "state": state,
                "metrics": {"temp": temp_c},
                "details": ""
            }}
