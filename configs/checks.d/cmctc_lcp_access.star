# cmctc_lcp_access check plugin for the yolo-man agent.
# Translated from Checkmk's cmctc_lcp_access / cmctc_lcp check plugin.
# The Rittal LCP device is queried via SNMP using the OIDs from _TREES
# (base .1.3.6.1.4.1.2606.4.2.{3..6}) — exactly the same data the Checkmk
# SNMP section "cmctc_lcp" fetches. We never substitute a local /proc or
# /sys value for this network appliance.

# Base OIDs per tree, mirror of _TREES in the Checkmk source.
_TREES = ["3", "4", "5", "6"]

# OID columns of one row within each tree's table (order matters — this is
# the SNMPTable column layout fetched by the Checkmk SNMPTree).
# index, typeid, status, reading, high, low, warn, description
_OID_COLUMNS = [
    "5.2.1.1",  # index
    "5.2.1.2",  # typeid
    "5.2.1.4",  # status
    "5.2.1.5",  # reading
    "5.2.1.6",  # high
    "5.2.1.7",  # low
    "5.2.1.8",  # warn
    "7.2.1.2",  # description
]

# Sensor type catalogue. typeid -> (subtype_label_or_None, sensortype_name)
_CMCTC_LCP_SENSORS = {
    "4": (None, "access"),
    "12": (None, "humidity"),
    "13": ("normally open", "user"),
    "14": ("normally closed", "user"),
    "23": (None, "flow"),
    "30": (None, "current"),
    "31": (None, "status"),
    "32": (None, "position"),
    "40": ("1", "blower"),
    "41": ("2", "blower"),
    "42": ("3", "blower"),
    "43": ("4", "blower"),
    "44": ("5", "blower"),
    "45": ("6", "blower"),
    "46": ("7", "blower"),
    "47": ("8", "blower"),
    "48": ("Server in 1", "temp"),
    "49": ("Server out 1", "temp"),
    "50": ("Server in 2", "temp"),
    "51": ("Server out 2", "temp"),
    "52": ("Server in 3", "temp"),
    "53": ("Server out 3", "temp"),
    "54": ("Server in 4", "temp"),
    "55": ("Server out 4", "temp"),
    "56": ("Overview Server in", "temp"),
    "57": ("Overview Server out", "temp"),
    "58": ("Water in", "temp"),
    "59": ("Water out", "temp"),
    "60": (None, "flow"),
    "61": (None, "blowergrade"),
    "62": (None, "regulator"),
}

# Sensor status code -> (state_level, text). Mirrors the Checkmk map.
_MAP_SENSOR_STATE = {
    "1": (3, "not available"),
    "2": (2, "lost"),
    "3": (1, "changed"),
    "4": (0, "ok"),
    "5": (2, "off"),
    "6": (0, "on"),
    "7": (1, "warning"),
    "8": (2, "too low"),
    "9": (2, "too high"),
    "10": (2, "error"),
}

# sensortype -> unit suffix shown in the summary.
_MAP_UNIT = {
    "access": "",
    "current": " A",
    "status": "",
    "position": "",
    "temp": " \u00b0C",
    "blower": " RPM",
    "blowergrade": "",
    "humidity": "%",
    "flow": " l/min",
    "regulator": "%",
    "user": "",
}


def _snmp_get(ctx, community, host, oid):
    """Fetch a single scalar OID, returning the bare value string or None.
    Uses -Oqv so net-snmp prints only the value (no type tag, no ' = ')."""
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
        ok_codes=[0],
    )
    if res.rc == 2 or res.rc == 127:
        return None
    if res.skipped:
        return None
    out = res.stdout.strip()
    if not out:
        return None
    return out


def _snmp_walk(ctx, community, host, oid):
    """Walk a numeric OID table, returning a list of (oid, value) pairs.
    Uses -Oqn: one line per row, '<oid> <value>'. Type tags are omitted."""
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
        ok_codes=[0],
    )
    if res.rc == 2 or res.rc == 127 or res.skipped:
        return []
    rows = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        space = line.find(" ")
        if space < 0:
            continue
        left = line[:space]
        right = line[space + 1:]
        rows.append((left, right))
    return rows


def _is_cmctc(ctx, community, host):
    """Probe for the real Rittal LCP device: read sysObjectID (.1.3.6.1.2.1.1.2.0)
    and confirm it contains the Rittal enterprise prefix .1.3.6.1.4.1.2606.4."""
    sysobj = _snmp_get(ctx, community, host, ".1.3.6.1.2.1.1.2.0")
    if sysobj == None:
        return False
    return sysobj.find(".1.3.6.1.4.1.2606") != -1


def _is_numeric(s):
    """True if s (after optional surrounding quotes) is a parseable float."""
    if s == None:
        return False
    s = s.strip()
    if s.startswith('"') and s.endswith('"'):
        s = s[1:-1]
    if s == "" or s == None:
        return False
    digits = "0123456789.+-eE"
    for ch in s:
        if digits.find(ch) < 0:
            return False
    return True


def _to_float(raw):
    """Convert a raw SNMP value string to float, guarding against non-numeric input."""
    if raw == None:
        return 0.0
    raw = raw.strip()
    if raw.startswith('"') and raw.endswith('"'):
        raw = raw[1:-1]
    if raw == "":
        return 0.0
    if not _is_numeric(raw):
        return 0.0
    return float(raw)


def _parse_row(row_dict):
    """Convert a {column-oid-suffix: raw_value} row into a Sensor-style dict."""
    index = row_dict.get("5.2.1.1", "")
    typeid = row_dict.get("5.2.1.2", "")
    status = row_dict.get("5.2.1.4", "")
    reading_raw = row_dict.get("5.2.1.5", "")
    high_raw = row_dict.get("5.2.1.6", "")
    low_raw = row_dict.get("5.2.1.7", "")
    warn_raw = row_dict.get("5.2.1.8", "")
    description = row_dict.get("7.2.1.2", "")

    return {
        "index": index,
        "typeid": typeid,
        "status": status,
        "reading": _to_float(reading_raw),
        "high": _to_float(high_raw),
        "low": _to_float(low_raw),
        "warn": _to_float(warn_raw),
        "description": description,
    }


def _parse_table(ctx, community, host, tree):
    """Walk one tree's 8 columns and return a list of parsed row dicts."""
    base = ".1.3.6.1.4.1.2606.4.2." + tree
    rows = {}
    for col in _OID_COLUMNS:
        col_oid = base + "." + col
        for oid, value in _snmp_walk(ctx, community, host, col_oid):
            # The row index is the OID suffix after the column base.
            if not oid.startswith(col_oid):
                continue
            suffix = oid[len(col_oid):]
            if suffix == "" or not suffix.startswith("."):
                continue
            index = suffix[1:]
            row = rows.get(index)
            if row == None:
                row = {}
                rows[index] = row
            row[col] = value
    return [_parse_row(r) for r in rows.values()]


def _build_section(ctx, community, host):
    """Mirror parse_cmctc_lcp: build {item: row_dict} for one host."""
    section = {}
    for tree in _TREES:
        for row in _parse_table(ctx, community, host, tree):
            typeid = row.get("typeid", "")
            sensor_spec = _CMCTC_LCP_SENSORS.get(typeid)
            if sensor_spec == None:
                continue
            label, type_ = sensor_spec
            index = row.get("index", "")
            if label != None:
                item = label + " - " + tree + "." + index
            else:
                item = tree + "." + index
            section[item] = {
                "type_": type_,
                "status": row.get("status", ""),
                "reading": row.get("reading", 0.0),
                "high": row.get("high", 0.0),
                "low": row.get("low", 0.0),
                "warn": row.get("warn", 0.0),
                "description": row.get("description", ""),
            }
    return section


def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    sensortype = params.get("sensortype", "access")
    item = params.get("item", "")

    # Discovery mode: enumerate the items this host actually exposes for the
    # requested sensortype.
    if params.get("_discover"):
        if not _is_cmctc(ctx, community, host):
            return {
                "changed": False,
                "msg": "Rittal LCP device not found",
                "data": {"discovery": []},
            }
        section = _build_section(ctx, community, host)
        discovery = []
        seen = {}
        for it, sensor in section.items():
            if sensor.get("type_") != sensortype:
                continue
            if seen.get(it) != None:
                continue
            seen[it] = True
            discovery.append({
                "item": it,
                "params": {},
                "metrics": [sensortype],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode: grade a single item.
    if not _is_cmctc(ctx, community, host):
        return {
            "changed": False,
            "msg": "Rittal LCP device not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    section = _build_section(ctx, community, host)
    sensor = section.get(item)
    if sensor == None:
        return {
            "changed": False,
            "msg": "no such sensor: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    unit = _MAP_UNIT.get(sensor.get("type_"), "")
    infotext = ""
    if sensor.get("description"):
        infotext = "[" + sensor["description"] + "] "

    status = sensor.get("status", "")
    state_pair = _MAP_SENSOR_STATE.get(status)
    if state_pair == None:
        state_level = 3
        extra_info = "unknown status"
    else:
        state_level = state_pair[0]
        extra_info = state_pair[1]

    reading = sensor.get("reading", 0.0)
    summary = infotext + str(int(reading)) + unit

    extra_state = 0
    levels = params.get("levels", None)
    low_v = sensor.get("low", 0.0)
    warn_v = sensor.get("warn", 0.0)
    high_v = sensor.get("high", 0.0)
    has_levels = (low_v != 0.0) or (warn_v != 0.0) or (high_v != 0.0)
    if levels != None and len(levels) == 2:
        warn, crit = levels[0], levels[1]
        if reading >= crit:
            extra_state = 2
        elif reading >= warn:
            extra_state = 1
        if extra_state:
            extra_info = extra_info + " (warn/crit at " + str(warn) + "/" + str(crit) + unit + ")"
    else:
        if has_levels:
            if (reading >= high_v) or (reading <= low_v):
                extra_state = 2
                extra_info = extra_info + " (device lower/upper crit at " + str(low_v) + "/" + str(high_v) + unit + ")"

    # The primary state combines the device status and any threshold breach.
    if extra_state > state_level:
        final_state = extra_state
    else:
        final_state = state_level

    state_names = ["OK", "WARN", "CRIT", "UNKNOWN"]
    state_name = state_names[final_state]
    metrics = {sensortype: reading}
    return {
        "changed": False,
        "msg": summary + " " + extra_info,
        "data": {
            "state": state_name,
            "metrics": metrics,
            "details": extra_info,
        },
    }