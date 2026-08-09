# HWG humidity check (SNMP-based) — read-only Starlark translation of checkmk.hwg_humidity.
# Monitors HWG humidity sensor values and states via SNMP.

DEFAULT_LEVELS = (60.0, 70.0)

map_units = {"1": "c", "2": "f", "3": "k", "4": "%"}

map_dev_states = {
    "0": "invalid",
    "1": "normal",
    "2": "out of range low",
    "3": "out of range high",
    "4": "alarm low",
    "5": "alarm high",
}

col_keys = {"1": "index", "2": "descr", "3": "sensorstatus",
            "4": "unit", "7": "current"}

base_oid = ".1.3.6.1.4.1.21796.4.1.3.1"


def safe_float(s):
    s = s.strip().strip('"')
    if s == "" or s == None:
        return None
    # Remove any trailing/leading non-numeric chars that could break float()
    # Handle negative values and decimals
    digits = "0123456789.-"
    cleaned = ""
    for ch in s:
        if ch in digits:
            cleaned = cleaned + ch
    if cleaned == "" or cleaned == "." or cleaned == "-" or cleaned == "-.":
        return None
    return float(cleaned)


def safe_int(s):
    s = s.strip().strip('"')
    if s == "" or s == None:
        return 0
    digits = "0123456789-"
    cleaned = ""
    for ch in s:
        if ch in digits:
            cleaned = cleaned + ch
    if cleaned == "" or cleaned == "-" or cleaned == "-.":
        return 0
    return int(cleaned)


def parse_hwg(info):
    """Reproduce the Checkmk parse_hwg function for humidity sensors.
    info is a list of [index, descr, sensorstatus, current, unit] rows.
    Returns a dict keyed by index with sensor data.
    """
    parsed = {}
    for row in info:
        if len(row) < 5:
            continue
        index = row[0]
        descr = row[1]
        sensorstatus = row[2]
        current = row[3]
        unit = row[4]

        # Determine if this is a humidity sensor
        ss_int = safe_int(sensorstatus)
        is_humidity = (ss_int != 0) and (map_units.get(unit, "") == "%")

        if is_humidity:
            humidity_val = safe_float(current)
            if humidity_val == None:
                continue
            parsed.setdefault(index, {
                "descr": descr,
                "humidity": humidity_val,
                "dev_status_name": map_dev_states.get(sensorstatus, "n.a."),
                "dev_status": sensorstatus,
            })
        else:
            temp_val = safe_float(current)
            parsed.setdefault(index, {
                "descr": descr,
                "dev_unit": map_units.get(unit),
                "temperature": temp_val,
                "dev_status_name": map_dev_states.get(sensorstatus, ""),
                "dev_status": sensorstatus,
            })

    return parsed


def check_humidity(value, params):
    """Reproduce the humidity threshold check logic.
    value is the humidity percentage. params contains 'levels' with (warn, crit).
    Returns (state, summary).
    """
    levels = params.get("levels", DEFAULT_LEVELS)
    warn = levels[0] if len(levels) >= 2 else 60.0
    crit = levels[1] if len(levels) >= 2 else 70.0

    state = "OK"
    if value >= crit:
        state = "CRIT"
    elif value >= warn:
        state = "WARN"

    summary = "Humidity: %f%%" % value
    return state, summary


def fetch_hwg_table(ctx, host, community):
    """Walk the HWG SNMP base OID and return a dict: index -> {col_key -> value}."""
    walk_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_oid],
        mutates=False,
    )
    if walk_res.rc != 0:
        return None

    rows = {}
    for line in walk_res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        full_oid = parts[0]
        value = parts[1].strip().strip('"')
        suffix = full_oid[len(base_oid):]
        oid_parts = suffix.split(".")
        if len(oid_parts) < 3:
            continue
        col = oid_parts[1]
        idx = ".".join(oid_parts[2:])
        if col not in col_keys:
            continue
        if idx not in rows:
            rows[idx] = {}
        rows[idx][col_keys[col]] = value

    return rows


def detect_hwg(ctx, host, community):
    """Check whether this is actually an HWG device via sysDescr."""
    detect_oid = ".1.3.6.1.2.1.1.1.0"
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, detect_oid],
        mutates=False,
    )
    if res.rc != 0:
        return False
    sysdescr = res.stdout.strip().lower()
    return "hwg" in sysdescr


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")
    levels = params.get("levels", DEFAULT_LEVELS)

    if params.get("_discover"):
        # Discovery mode: probe the device first
        if not detect_hwg(ctx, host, community):
            return {"changed": False, "msg": "not installed",
                    "data": {"discovery": []}}

        rows = fetch_hwg_table(ctx, host, community)
        if rows == None:
            return {"changed": False, "msg": "SNMP walk failed",
                    "data": {"discovery": []}}

        # Build info list for parse_hwg
        info_list = []
        for idx in rows:
            row_data = rows[idx]
            info_list.append([
                row_data.get("index", idx),
                row_data.get("descr", ""),
                row_data.get("sensorstatus", "0"),
                row_data.get("current", ""),
                row_data.get("unit", "4"),
            ])

        parsed = parse_hwg(info_list)

        discovery = []
        for index, attrs in parsed.items():
            if attrs.get("humidity") != None:
                discovery.append({
                    "item": index,
                    "params": {"levels": list(levels)},
                    "metrics": ["humidity"],
                })

        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode: check a specific item
    rows = fetch_hwg_table(ctx, host, community)
    if rows == None:
        return {"changed": False,
                "msg": "SNMP walk failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Find the requested item
    row_data = rows.get(item)
    if row_data == None:
        return {"changed": False,
                "msg": "no such item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Build the info row for parse_hwg
    info_list = [[row_data.get("index", item),
                  row_data.get("descr", ""),
                  row_data.get("sensorstatus", "0"),
                  row_data.get("current", ""),
                  row_data.get("unit", "4")]]

    parsed = parse_hwg(info_list)
    data = parsed.get(item)

    if data == None or data.get("humidity") == None:
        return {"changed": False,
                "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state, summary = check_humidity(data["humidity"], {"levels": levels})
    details = "Description: %s, Status: %s" % (
        data.get("descr", ""), data.get("dev_status_name", ""))
    msg = "%s, %s" % (summary, details)

    return {"changed": False,
            "msg": msg,
            "data": {"state": state,
                     "metrics": {"humidity": data["humidity"]},
                     "details": details}}