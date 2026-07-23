# ===== Module-level constants =====

# Base OIDs for each SNMP table (3, 4, 5, 6) per Checkmk source
_BASE_OIDS = [
    ".1.3.6.1.4.1.2606.4.2.3.5.2.1",
    ".1.3.6.1.4.1.2606.4.2.4.5.2.1",
    ".1.3.6.1.4.1.2606.4.2.5.5.2.1",
    ".1.3.6.1.4.1.2606.4.2.6.5.2.1",
]

# Status translation: Checkmk status code -> agent status code
_CMCTC_STATUS_MAP = {
    4: 0,   # ok
    7: 1,   # warning
    8: 1,   # too low
    9: 2,   # too high
}

# Status name mapping for the "Unit:" string in Checkmk
_CMCTC_STATUS_TEXT_MAP = {
    1: "notAvail",
    2: "lost",
    3: "changed",
    4: "ok",
    5: "off",
    6: "on",
    7: "warning",
    8: "tooLow",
    9: "tooHigh",
}

# ===== Helper functions =====

def _translate_status(status):
    return _CMCTC_STATUS_MAP.get(status, 3)

def _translate_status_text(status):
    return _CMCTC_STATUS_TEXT_MAP.get(status, "UNKNOWN")

def _get_snmp_value(snmp_output, base_oid, offset_idx):
    """Extract value for a specific OID and offset"""
    key = str(offset_idx)
    if key in snmp_output and len(snmp_output[key]) > 0:
        return snmp_output[key][0].split(": ", 1)[1].strip().strip('"')
    return "0"

def _walk_snmp(ctx, base_oid):
    """Walk a single OID and return parsed values"""
    res = ctx.run(["snmpwalk", "-v2c", "-c", ctx.facts().get("snmp_community", "public"),
                   "-On", ctx.facts().get("hostname", "localhost"), base_oid], mutates=False)
    out = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        # Extract the numeric suffix (item index)
        suffix = oid_part[len(base_oid)+1:] if oid_part.startswith(base_oid + ".") else ""
        if suffix:
            idx = suffix
            # Extract value part after "STRING: " or "INTEGER: " etc.
            if value_part.startswith("STRING: "):
                value = value_part[8:].strip().strip('"')
            elif value_part.startswith("INTEGER: "):
                value = value_part[9:].strip()
            else:
                value = value_part.split(": ", 1)[1] if ": " in value_part else value_part
            if idx not in out:
                out[idx] = {}
            out[idx] = value
    return out

def _parse_snmp_data(ctx):
    """Parse all four SNMP tables for temperature sensors"""
    combined = {}
    for table_idx in range(len(_BASE_OIDS)):
        base_oid = _BASE_OIDS[table_idx]
        # Walk all required OIDs
        index_oid = base_oid + ".1"
        type_oid = base_oid + ".2"
        status_oid = base_oid + ".4"
        reading_oid = base_oid + ".5"
        crit_oid = base_oid + ".6"
        low_oid = base_oid + ".7"
        warn_oid = base_oid + ".8"
        
        idxs = _walk_snmp(ctx, index_oid).keys()
        type_vals = _walk_snmp(ctx, type_oid)
        status_vals = _walk_snmp(ctx, status_oid)
        reading_vals = _walk_snmp(ctx, reading_oid)
        crit_vals = _walk_snmp(ctx, crit_oid)
        low_vals = _walk_snmp(ctx, low_oid)
        warn_vals = _walk_snmp(ctx, warn_oid)
        
        for idx in idxs:
            type_val = type_vals.get(idx, "0")
            if type_val.isdigit() and int(type_val) == 10:
                status = int(status_vals.get(idx, "3"))
                reading = int(reading_vals.get(idx, "0"))
                warn = float(warn_vals.get(idx, "0"))
                crit = float(crit_vals.get(idx, "0"))
                low = float(low_vals.get(idx, "0"))
                
                combined[idx] = {
                    "status": status,
                    "reading": reading,
                    "levels": (warn, crit),
                    "levels_lower": (low, float("-inf")),
                }
    return combined

# ===== main function =====

def main(ctx, params):
    # ===== Discovery mode =====
    if params.get("_discover"):
        section = _parse_snmp_data(ctx)
        discovery = []
        for item in section:
            discovery.append({
                "item": item,
                "params": {},
                "metrics": ["temp"],
            })
        return {
            "changed": False,
            "msg": "discovered " + str(len(discovery)) + " temperature sensors",
            "data": {"discovery": discovery},
        }

    # ===== Check mode =====
    item = params.get("item", "")
    section = _parse_snmp_data(ctx)
    sensor = section.get(item)
    if sensor == None:
        return {
            "changed": False,
            "msg": "sensor " + item + " not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    reading = float(sensor["reading"])
    warn = params.get("warn", sensor["levels"][0])
    crit = params.get("crit", sensor["levels"][1])
    warn_low = sensor["levels_lower"][0]
    status = sensor["status"]
    status_code = _translate_status(status)
    status_text = _translate_status_text(status)

    # Determine state based on thresholds
    if status_code == 2 or reading >= crit:
        state = "CRIT"
    elif status_code == 1 or reading >= warn:
        state = "WARN"
    elif status_code == 0:
        state = "OK"
    else:
        state = "UNKNOWN"

    # Lower threshold check (if warn_low is non-zero)
    if reading <= warn_low and warn_low != float("-inf"):
        if state != "CRIT":
            state = "WARN"

    msg = "Temperature: " + str(reading) + " C"
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temp": reading},
            "details": "Status: " + status_text,
        },
    }
