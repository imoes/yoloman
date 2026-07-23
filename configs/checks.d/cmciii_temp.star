DIGITS = "0123456789"
BASE_OID = ".1.3.6.1.4.1.2606.7.4.2.2.1"
COL_NAME_OID = BASE_OID + ".3"
COL_VALUE_OID = BASE_OID + ".4"
SETPT_FIELDS = ["SetPtHighWarning", "SetPtHighAlarm", "SetPtLowWarning", "SetPtLowAlarm"]

def _strip_snmp_val(raw):
    s = raw.strip()
    for pfx in ["STRING: \"", "STRING: ", "INTEGER: ", "Gauge32: ", "Counter32: "]:
        if s.startswith(pfx):
            s = s[len(pfx):]
            break
    if s.endswith("\""):
        s = s[:-1]
    return s.strip()

def _walk_col(ctx, host, community, col_oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-On", host, col_oid],
        mutates=False, ok_codes=[0, 1]
    )
    data = {}
    pfx = col_oid + "."
    for line in res.stdout.splitlines():
        eq = line.find(" = ")
        if eq < 0:
            continue
        full_oid = line[:eq].strip()
        raw = line[eq+3:]
        if not full_oid.startswith(pfx):
            continue
        suffix = full_oid[len(pfx):]
        data[suffix] = _strip_snmp_val(raw)
    return data

def _to_float(s):
    s = s.strip()
    if not s:
        return None
    neg = s.startswith("-")
    body = s[1:] if neg else s
    dot_count = 0
    ok = True
    for c in body:
        if c == ".":
            dot_count += 1
            if dot_count > 1:
                ok = False
                break
        elif c not in DIGITS:
            ok = False
            break
    if not ok or not body:
        return None
    return float(s)

def _parse_num(raw):
    parts = raw.split()
    token = parts[0] if parts else ""
    clean = ""
    for c in token:
        if c in DIGITS or c == ".":
            clean += c
        elif c == "-" and not clean:
            clean += c
    return _to_float(clean)

def _collect_sensors(ctx, host, community):
    names = _walk_col(ctx, host, community, COL_NAME_OID)
    vals = _walk_col(ctx, host, community, COL_VALUE_OID)

    # group by "unit@name_prefix" -> {field: oid_suffix}
    # e.g. "2@Air.Temperature" -> {"DescName": "2.6", "Value": "2.7", ...}
    groups = {}
    for suffix, name in names.items():
        dot = suffix.find(".")
        if dot < 0:
            continue
        unit = suffix[:dot]
        name_parts = name.split(".")
        if len(name_parts) < 2:
            continue
        field = name_parts[-1]
        prefix = ".".join(name_parts[:-1])
        if "Temperature" not in prefix:
            continue
        gkey = unit + "@" + prefix
        if gkey not in groups:
            groups[gkey] = {}
        groups[gkey][field] = suffix

    sensors = {}
    for gkey, field_map in groups.items():
        if "Value" not in field_map:
            continue
        at = gkey.find("@")
        unit = gkey[:at]
        prefix = gkey[at+1:]
        loc_parts = prefix.split(".")
        location = loc_parts[0] if loc_parts else prefix

        sensor = {"_unit_": unit, "_location_": location, "_prefix_": prefix}
        for field, sfx in field_map.items():
            raw = vals.get(sfx, "")
            if field == "Value" or field in SETPT_FIELDS:
                num = _parse_num(raw)
                if num != None:
                    sensor[field] = num
            else:
                sensor[field] = raw

        # key = OID suffix of the Value row (mirrors Checkmk's id_ convention)
        sensors[field_map["Value"]] = sensor

    return sensors

def _device_levels(sensor, kw, kc):
    w = sensor.get(kw)
    c = sensor.get(kc)
    if w != None and c != None:
        return (w, c)
    if w != None:
        return (w, w)
    if c != None:
        return (c, c)
    return None

def _eval_state(value, upper, lower):
    state = "OK"
    if upper != None:
        if value >= upper[1]:
            state = "CRIT"
        elif value >= upper[0]:
            state = "WARN"
    if lower != None:
        if value <= lower[1]:
            state = "CRIT"
        elif value <= lower[0] and state != "CRIT":
            state = "WARN"
    return state

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        sensors = _collect_sensors(ctx, host, community)
        disc = []
        for item_id, sensor in sensors.items():
            if "Value" not in sensor:
                continue
            disc.append({
                "item": item_id,
                "params": {
                    "host": host,
                    "community": community,
                    "warn": 25.0,
                    "crit": 30.0,
                },
                "metrics": ["temp"],
            })
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(disc),
            "data": {"discovery": disc},
        }

    item = params.get("item", "")
    sensors = _collect_sensors(ctx, host, community)
    sensor = sensors.get(item)

    if sensor == None:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    value = sensor.get("Value")
    if value == None:
        return {
            "changed": False,
            "msg": "no temperature reading for: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    upper = _device_levels(sensor, "SetPtHighWarning", "SetPtHighAlarm")
    lower = _device_levels(sensor, "SetPtLowWarning", "SetPtLowAlarm")

    if upper == None:
        warn = params.get("warn", 25.0)
        crit = params.get("crit", 30.0)
        upper = (float(warn), float(crit))

    state = _eval_state(value, upper, lower)

    dev_status = sensor.get("Status", "")
    status_lc = dev_status.lower()
    if status_lc in ["alarm", "critical", "error"]:
        state = "CRIT"
    elif status_lc in ["warning", "warn"] and state == "OK":
        state = "WARN"

    desc = sensor.get("DescName", "")
    desc_clean = desc.replace("Temperature", "").strip()
    summary = "%f C" % value
    if desc_clean and desc_clean not in item:
        summary = "[%s] %s" % (desc_clean, summary)
    if dev_status and status_lc != "ok":
        summary = summary + " (Device: %s)" % dev_status

    detail_parts = []
    if upper != None:
        detail_parts.append("High warn/crit: %f/%f C" % (upper[0], upper[1]))
    if lower != None:
        detail_parts.append("Low warn/crit: %f/%f C" % (lower[0], lower[1]))
    details = ", ".join(detail_parts)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"temp": value},
            "details": details,
        },
    }