# Module-level constants for SNMP OIDs
_BASE_OID_10GM = ".1.3.6.1.4.1.3652.3.3.4"
_OID_SLOT = "1.1.2"
_OID_TEMP = "1.1.7"
_OID_WARN = "2.1.13"
_OID_CRIT = "2.1.14"

_DEFAULT_LEVELS = (35.0, 40.0)


def _walk_snmp(ctx, community, host, base_oid):
    """Walk an SNMP tree and return lines like 'OID = TYPE: value'"""
    res = ctx.run(
        [
            "snmpwalk",
            "-v2c",
            "-c",
            community,
            "-On",
            host,
            base_oid,
        ],
        mutates=False,
    )
    if res.rc != 0:
        return []
    return res.stdout.splitlines()


def _parse_snmp_lines(lines):
    """Parse SNMP walk output into dict: {slot: {"temp": float, "warn": float, "crit": float}}"""
    slots = {}
    for line in lines:
        if " = " not in line:
            continue
        oid_part, val_part = line.split(" = ", 1)
        if ":" in val_part:
            val_type, val = val_part.split(":", 1)
            val = val.strip()
        else:
            val = val_part.strip()
            val_type = ""
        # Extract the last number in the OID (the slot index)
        oid_parts = oid_part.split(".")
        if len(oid_parts) < 2:
            continue
        index = oid_parts[-1]
        # Map OIDs to types: slot (1.1.2), temp (1.1.7), warn (2.1.13), crit (2.1.14)
        # We only care about 10GM module (base .1.3.6.1.4.1.3652.3.3.4)
        base = ".".join(oid_parts[:-1])
        if base == _BASE_OID_10GM + "." + _OID_SLOT:
            slots.setdefault(index, {})["slot"] = val
        elif base == _BASE_OID_10GM + "." + _OID_TEMP:
            if val.isdigit():
                slots.setdefault(index, {})["temp"] = float(val)
        elif base == _BASE_OID_10GM + "." + _OID_WARN:
            if val.isdigit():
                slots.setdefault(index, {})["warn"] = float(val)
        elif base == _BASE_OID_10GM + "." + _OID_CRIT:
            if val.isdigit():
                slots.setdefault(index, {})["crit"] = float(val)
    return slots


def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    levels = params.get("levels", _DEFAULT_LEVELS)

    # Discovery mode: enumerate items
    if params.get("_discover"):
        lines = _walk_snmp(ctx, community, host, _BASE_OID_10GM)
        parsed = _parse_snmp_lines(lines)
        items = []
        for slot_id, data in sorted(parsed.items()):
            if "slot" in data:
                item_name = str(data["slot"])
                items.append({
                    "item": item_name,
                    "params": {"levels": _DEFAULT_LEVELS},
                    "metrics": ["temperature"]
                })
        return {
            "changed": False,
            "msg": "discovered %d 10GM modules" % len(items),
            "data": {"discovery": items},
        }

    # Check mode: verify single item
    item = params.get("item", "")
    lines = _walk_snmp(ctx, community, host, _BASE_OID_10GM)
    parsed = _parse_snmp_lines(lines)
    slot_data = None
    for slot_id, data in parsed.items():
        if "slot" in data and str(data["slot"]) == item:
            slot_data = data
            break

    if slot_data == None or "temp" not in slot_data:
        return {
            "changed": False,
            "msg": "temperature sensor not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    temp = slot_data["temp"]
    warn = slot_data.get("warn", levels[0])
    crit = slot_data.get("crit", levels[1])

    # Determine state based on thresholds (upper bounds)
    state = "OK"
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"

    msg = "Temperature 10GM Module %s: %f °C" % (item, temp)
    if warn != None and crit != None:
        msg += " (warn at %f °C, crit at %f °C)" % (warn, crit)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temperature": temp},
            "details": "",
        },
    }