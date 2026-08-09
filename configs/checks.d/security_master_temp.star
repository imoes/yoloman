# Translated Checkmk check plugin: security_master_temp (SNMP)
# Source plugin: cmk/plugins/security_master/agent_based/security_master.py
# This is a read-only Starlark check module for the yolo-man agent.

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
OID_BASE = "1.3.6.1.4.1.35491.30"
OID_SYSDESCR = "1.3.6.1.2.1.1.2.0"

SUPPORTED_SENSORS = {
    50: "temp",
    60: "humidity",
    72: "smoke",
}

# Map an alarm integer to (lower_crit, lower_warn, warn, crit) for temp/humidity
# Not used directly here, but documentation of the source's alarm scale.
#  -1 = no value, 2 = lower warn, 4 = upper warn, 5 = upper crit

# ---------------------------------------------------------------------------
# Helpers (Starlark has no exceptions, guard with if/defaults)
# ---------------------------------------------------------------------------

def _safe_int(s):
    if s == None:
        return 0
    t = str(s).strip()
    neg = False
    if t.startswith("-"):
        neg = True
        t = t[1:]
    if t.isdigit():
        v = 0
        for ch in t:
            v = v * 10 + (ord(ch) - 48)
        return -v if neg else v
    return 0

def _safe_float(s):
    if s == None:
        return 0.0
    t = str(s).strip()
    if t == "":
        return 0.0
    neg = False
    if t.startswith("-"):
        neg = True
        t = t[1:]
    elif t.startswith("+"):
        t = t[1:]
    # handle simple "12", "12.3", "-1.5"
    parts = t.split(".")
    ok = len(parts) == 1 or (len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit())
    if len(parts) == 1:
        ok = parts[0].isdigit()
    if not ok:
        return 0.0
    if len(parts) == 1:
        v = 0
        for ch in parts[0]:
            v = v * 10 + (ord(ch) - 48)
        return -float(v) if neg else float(v)
    intpart = 0
    for ch in parts[0]:
        intpart = intpart * 10 + (ord(ch) - 48)
    frac = 0
    for ch in parts[1]:
        frac = frac * 10 + (ord(ch) - 48)
    scale = 1
    for _ in parts[1]:
        scale = scale * 10
    val = float(intpart) + float(frac) / float(scale)
    return -val if neg else val

# ---------------------------------------------------------------------------
# SNMP data gathering + parsing
# ---------------------------------------------------------------------------

def _snmp_walk_raw(ctx, community, host, column_oid):
    # -Oqn: numeric OIDs, no type tag, one "OID value" line per row
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout

def _parse_walk_table(walk_out, column_oid):
    """Return list of (index, value) from a -Oqn snmpwalk on column_oid."""
    rows = []
    if walk_out == None or walk_out == "":
        return rows
    for line in walk_out.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        line_oid = line[:sp]
        value = line[sp + 1:]
        if not line_oid.startswith(column_oid + "."):
            continue
        index = line_oid[len(column_oid) + 1:]
        rows.append((index, value))
    return rows

def _snmp_get_raw(ctx, community, host, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()

def _gather_security_master(ctx, community, host):
    """Walk the sensor table and return parsed dict[str, dict[str, section]].

    Structure mirrors parse_security_master:
        {"temp": {service_name: {...fields...}}, "humidity": {...}, "smoke": {...}}
    """
    parsed = {"temp": {}, "humidity": {}, "smoke": {}}

    # The source walks base .1.3.6.1.4.1.35491.30 oids=[OIDEnd(), "3"]
    # i.e. it walks column .3 (Sensor Group1 / sensor name) under .30.
    walk_out = _snmp_walk_raw(ctx, community, host, OID_BASE)
    if walk_out == None or walk_out == "":
        return None

    # Each line: "<full_oid> <value>"; -Oqn keeps numeric OIDs.
    # The full OID looks like: 1.3.6.1.4.1.35491.30.3.<sensor>.<field>.0
    # We only process entries whose OID contains ".5.0" (the name field), per source.
    by_num = {}  # num -> name
    for line in walk_out.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        full_oid = line[:sp]
        value = line[sp + 1:]
        # Only consider sensor name entries (.5.0) per source's `if ".5.0" not in str(oid)`
        if ".5.0" not in full_oid:
            continue
        # num is the sensor group number: parts[0] of the source oid
        # full_oid == OID_BASE + ".3." + num + ".5.0"
        prefix = OID_BASE + ".3."
        if not full_oid.startswith(prefix):
            continue
        rest = full_oid[len(prefix):]  # e.g. "50.5.0"
        num = rest.split(".")[0]
        by_num[num] = value

    # For each sensor number, fetch the other fields via snmpget on known OIDs.
    # Source layout (relative to .1.3.6.1.4.1.35491.30.3.<num>):
    #   .1.0 sensor ID
    #   .2.0 value
    #   .3.0 unit
    #   .4.0 valueint
    #   .5.0 name  (already have)
    #   .6.0 alarmint
    #   .7.0 LoLimitAlarmInt (crit low)
    #   .8.0 LoLimitWarnInt  (warn low)
    #   .9.0 HiLimitWarnInt  (warn high)
    #   .10.0 HiLimitAlarmInt (crit high)
    #   .11.0 HysterInt
    for num, name in by_num.items():
        sensor_id = 0
        value = None
        alarm = -1
        crit_low = 0.0
        warn_low = 0.0
        warn_high = 0.0
        crit_high = 0.0

        sid_str = _snmp_get_raw(ctx, community, host, OID_BASE + ".3." + num + ".1.0")
        if sid_str != None:
            # Source does: saveint(sensor_second[0].encode("utf-8").hex())
            # i.e. take first byte of the (string) value, hex-encode, parse int.
            b = sid_str
            # encode utf-8 hex of first char
            first_ord = ord(b[0]) if len(b) > 0 else 0
            sensor_id = first_ord
            if first_ord > 127:
                # two-byte utf-8 would change the hex; keep simple: use ord of first char
                sensor_id = first_ord

        val_str = _snmp_get_raw(ctx, community, host, OID_BASE + ".3." + num + ".2.0")
        if val_str != None and val_str != "":
            value = _safe_float(val_str)

        al_str = _snmp_get_raw(ctx, community, host, OID_BASE + ".3." + num + ".6.0")
        if al_str != None and al_str != "":
            try_alarm = _safe_int(al_str)
            if try_alarm == 0 and not al_str.strip().lstrip("-").isdigit():
                alarm = -1
            else:
                alarm = try_alarm

        cl_str = _snmp_get_raw(ctx, community, host, OID_BASE + ".3." + num + ".7.0")
        if cl_str != None:
            crit_low = _safe_int(cl_str) / 1000.0

        wl_str = _snmp_get_raw(ctx, community, host, OID_BASE + ".3." + num + ".8.0")
        if wl_str != None:
            warn_low = _safe_int(wl_str) / 1000.0

        wh_str = _snmp_get_raw(ctx, community, host, OID_BASE + ".3." + num + ".9.0")
        if wh_str != None:
            warn_high = _safe_int(wh_str) / 1000.0

        ch_str = _snmp_get_raw(ctx, community, host, OID_BASE + ".3." + num + ".10.0")
        if ch_str != None:
            crit_high = _safe_int(ch_str) / 1000.0

        service_name = num + " " + name

        if sensor_id in SUPPORTED_SENSORS:
            stype = SUPPORTED_SENSORS[sensor_id]
            parsed[stype][service_name] = {
                "name": name,
                "value": value,
                "id": sensor_id,
                "levels_low": (warn_low, crit_low),
                "levels": (warn_high, crit_high),
                "alarm": alarm,
            }

    return parsed

# ---------------------------------------------------------------------------
# Threshold application (check_temperature semantics)
# ---------------------------------------------------------------------------

def _apply_temperature_levels(value, params, dev_levels, dev_levels_lower):
    """Mimic cmk.plugins.lib.temperature.check_temperature upper/lower levels.

    params may carry: warn, crit, levels=(warn,crit), levels_lower=(warn,crit)
    dev_levels / dev_levels_lower are device-provided (warn,crit) tuples.

    device_levels_handling default is "worst" -> device levels are combined
    with operator levels taking precedence only if defined.
    We replicate the "worst" semantics: if device defines levels, use them
    unless operator levels are set; grade value against the effective levels.
    """
    warn = None
    crit = None
    warn_lower = None
    crit_lower = None

    # Operator levels
    levels = params.get("levels")
    if levels != None:
        warn = levels[0]
        crit = levels[1]

    levels_lower = params.get("levels_lower")
    if levels_lower != None:
        warn_lower = levels_lower[0]
        crit_lower = levels_lower[1]

    # Fallbacks for direct warn/crit params
    if params.get("warn") != None:
        warn = params.get("warn")
    if params.get("crit") != None:
        crit = params.get("crit")
    if params.get("warn_lower") != None:
        warn_lower = params.get("warn_lower")
    if params.get("crit_lower") != None:
        crit_lower = params.get("crit_lower")

    # Device levels (used when operator levels absent)
    if dev_levels != None and warn == None and crit == None:
        warn = dev_levels[0]
        crit = dev_levels[1]
    if dev_levels_lower != None and warn_lower == None and crit_lower == None:
        warn_lower = dev_levels_lower[0]
        crit_lower = dev_levels_lower[1]

    state = "OK"
    detail = ""

    # Upper thresholds
    if crit != None and value >= crit:
        state = "CRIT"
    elif warn != None and value >= warn and state == "OK":
        state = "WARN"

    # Lower thresholds
    if crit_lower != None and value <= crit_lower:
        state = "CRIT"
    elif warn_lower != None and value <= warn_lower and state == "OK":
        state = "WARN"

    if state == "CRIT":
        detail = "CRIT - Temperature %f" % value
    elif state == "WARN":
        detail = "WARN - Temperature %f" % value
    else:
        detail = "OK - Temperature %f" % value

    return state, detail

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main(ctx, params):
    # Required SNMP params (mirrors SNMP check convention)
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Discovery mode
    if params.get("_discover"):
        parsed = _gather_security_master(ctx, community, host)
        if parsed == None:
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }
        out = []
        # Only temp sensors are discovered by THIS check (security_master_temp)
        for item in parsed["temp"]:
            out.append({
                "item": item,
                "params": {"device_levels_handling": "worst"},
                "metrics": ["temperature"],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(out),
            "data": {"discovery": out},
        }

    # Check mode: single item
    item = params.get("item", "")

    parsed = _gather_security_master(ctx, community, host)
    if parsed == None:
        return {
            "changed": False,
            "msg": "no SNMP response from security master device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sensor = parsed["temp"].get(item)
    if sensor == None or len(sensor) == 0:
        return {
            "changed": False,
            "msg": "Sensor not found in SNMP output",
            "data": {"state": "UNKNOWN", "metrics": {"temperature": 0}, "details": ""},
        }

    sensor_value = sensor["value"]
    if sensor_value == None:
        return {
            "changed": False,
            "msg": "Sensor value is not in SNMP-WALK",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    dev_levels = None
    if sensor["levels"][0] != None:
        dev_levels = sensor["levels"]

    dev_levels_lower = None
    if sensor["levels_low"][0] != None:
        dev_levels_lower = sensor["levels_low"]

    state, detail = _apply_temperature_levels(
        sensor_value, params, dev_levels, dev_levels_lower
    )

    msg = "%s %s" % (item, detail)
    # Build a Checkmk-style summary: Sensor <num> <name> ... temp
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temperature": sensor_value},
            "details": detail,
        },
    }