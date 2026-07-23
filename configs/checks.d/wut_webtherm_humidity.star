_MULTI_SENSOR_IDXS = [16, 18, 36, 37, 38, 42]
_BASE_OID_TMPL = ".1.3.6.1.4.1.5040.1.2.%d.1"

def _snmp_scalar(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
        ok_codes=[0, 1, 2],
    )
    if res.rc != 0:
        return ""
    val = res.stdout.strip().strip('"')
    if "No Such" in val or "not available" in val:
        return ""
    return val

def _parse_float(s):
    s = s.strip().replace(",", ".")
    if not s or "---" in s:
        return None
    parts = s.split()
    candidate = parts[0] if parts else s
    clean = candidate.replace(".", "").replace("-", "")
    if not clean or not clean.isdigit():
        return None
    return float(candidate)

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        discovered = []
        for idx in _MULTI_SENSOR_IDXS:
            base = _BASE_OID_TMPL % idx
            sensor_id = _snmp_scalar(ctx, host, community, base + ".2.1.1")
            if sensor_id != "2":
                continue
            reading_en = _snmp_scalar(ctx, host, community, base + ".8.1.1")
            reading_de = _snmp_scalar(ctx, host, community, base + ".3.1.1")
            reading_str = reading_en if reading_en else reading_de
            if _parse_float(reading_str) == None:
                continue
            discovered.append({
                "item": sensor_id,
                "params": {
                    "levels": (60.0, 65.0),
                    "levels_lower": (40.0, 35.0),
                },
                "metrics": ["humidity"],
            })
        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(discovered),
            "data": {"discovery": discovered},
        }

    item = params.get("item", "2")
    levels = params.get("levels", (60.0, 65.0))
    levels_lower = params.get("levels_lower", (40.0, 35.0))
    warn_upper = levels[0]
    crit_upper = levels[1]
    warn_lower = levels_lower[0]
    crit_lower = levels_lower[1]

    reading = None
    for idx in _MULTI_SENSOR_IDXS:
        base = _BASE_OID_TMPL % idx
        sensor_id = _snmp_scalar(ctx, host, community, base + ".2.1.1")
        if sensor_id != item:
            continue
        reading_en = _snmp_scalar(ctx, host, community, base + ".8.1.1")
        reading_de = _snmp_scalar(ctx, host, community, base + ".3.1.1")
        reading_str = reading_en if reading_en else reading_de
        reading = _parse_float(reading_str)
        break

    if reading == None:
        return {
            "changed": False,
            "msg": "Humidity sensor %s not found or no data" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if reading >= crit_upper:
        state = "CRIT"
    elif reading >= warn_upper:
        state = "WARN"
    elif reading <= crit_lower:
        state = "CRIT"
    elif reading <= warn_lower:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "Humidity: %f%%" % reading,
        "data": {
            "state": state,
            "metrics": {"humidity": reading},
            "details": "",
        },
    }