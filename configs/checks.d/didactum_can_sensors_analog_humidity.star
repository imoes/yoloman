# ===== checkmk.didactum_can_sensors_analog_humidity =====
# Translated from Checkmk check plugin to a read-only Starlark check module.
# The source is an SNMP check (SimpleSNMPSection over .1.3.6.1.4.1.46501.6.2.1).
# It parses a table of CAN analog sensors, each with type/name/status/value/levels.

# State name -> numeric Checkmk state (0=OK, 1=WARN, 2=CRIT, 3=UNKNOWN)
_STATE_MAP = {
    "alarm": 2,
    "high alarm": 2,
    "low alarm": 2,
    "warning": 1,
    "high warning": 1,
    "low warning": 1,
    "normal": 0,
    "not connected": 3,
    "on": 0,
    "off": 3,
}

# SNMP walk base OIDs as column index -> (column name, oid-suffix)
# Tree columns 4..13 (per SNMPTree oids=["4","5","6","7","10","11","12","13"]):
#  4: type   5: name   6: status   7: value
# 10: crit_lower 11: warn_lower 12: warn 13: crit
COL_TYPE = "4"
COL_NAME = "5"
COL_STATUS = "6"
COL_VALUE = "7"
COL_CRIT_LOWER = "10"
COL_WARN_LOWER = "11"
COL_WARN = "12"
COL_CRIT = "13"

ALL_COLUMNS = [
    COL_TYPE, COL_NAME, COL_STATUS, COL_VALUE,
    COL_CRIT_LOWER, COL_WARN_LOWER, COL_WARN, COL_CRIT,
]


def _probe_product_exists(ctx, host, community):
    """Confirm a Didactum CAN device is actually present before discovering services."""
    sysOID = ".1.3.6.1.2.1.1.1.0"
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, sysOID],
        mutates=False,
    )
    if res.rc == 127:
        return False
    if res.rc != 0 or res.stdout == "":
        return False
    return "didactum" in res.stdout.lower()


def _walk_column(ctx, host, community, base, col):
    """Walk one SNMP column, return {index: value} mapping (index = oid suffix after column)."""
    oid = base + "." + col
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    out = {}
    if res.rc != 0 or res.stdout == "":
        return out
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        full_oid = parts[0]
        value = parts[1]
        # index is the suffix after the column oid
        prefix = oid + "."
        if not full_oid.startswith(prefix):
            continue
        idx = full_oid[len(prefix):]
        if idx == "":
            continue
        out[idx] = _strip_snmp_value(value)
    return out


def _strip_snmp_value(value):
    """Remove the trailing TYPE: tag that -Oqn may include, and quotes."""
    # -Oqn already strips the type tag; but guard against leading/trailing quotes
    v = value
    if v.startswith('"') and v.endswith('"') and len(v) >= 2:
        v = v[1:-1]
    return v


def _build_section(ctx, host, community, base):
    """Walk all columns and assemble the parsed section dict.

    Returns: {type: {name: {state, state_readable, value, levels, levels_lower}}}
    """
    col_values = {}
    for col in ALL_COLUMNS:
        col_values[col] = _walk_column(ctx, host, community, base, col)

    # Collect the union of indices that have a name (COL_NAME) value.
    indices = list(col_values[COL_NAME].keys())

    parsed = {}
    # Order types by their first-seen index ordering for stability
    for idx in indices:
        ty = col_values[COL_TYPE].get(idx, "")
        name = col_values[COL_NAME].get(idx, idx)
        status = col_values[COL_STATUS].get(idx, "")
        value_str = col_values[COL_VALUE].get(idx, "")
        crit_lower_str = col_values[COL_CRIT_LOWER].get(idx, "")
        warn_lower_str = col_values[COL_WARN_LOWER].get(idx, "")
        warn_str = col_values[COL_WARN].get(idx, "")
        crit_str = col_values[COL_CRIT].get(idx, "")

        if status in _STATE_MAP:
            state = _STATE_MAP[status]
            state_readable = status
        else:
            state = 3
            state_readable = "unknown[%s]" % status

        sensor = {
            "state": state,
            "state_readable": state_readable,
        }

        # value: int if isdigit, else float, else string
        if value_str != "":
            if value_str.lstrip("-").isdigit():
                sensor["value"] = int(value_str)
            else:
                is_float = False
                try_val = value_str.lstrip("-")
                parts = try_val.split(".", 1)
                if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
                    is_float = True
                if is_float:
                    sensor["value"] = float(value_str)
                else:
                    sensor["value"] = value_str

        # levels: (warn, crit) upper; levels_lower: (warn_lower, crit_lower)
        # Only set if all four are present (line == 8 equivalent)
        if (crit_lower_str != "" and warn_lower_str != ""
                and warn_str != "" and crit_str != ""):
            crit_lower = float(crit_lower_str)
            warn_lower = float(warn_lower_str)
            warn = float(warn_str)
            crit = float(crit_str)
            sensor["levels"] = (warn, crit)
            sensor["levels_lower"] = (warn_lower, crit_lower)

        parsed.setdefault(ty, {}).setdefault(name, sensor)

    return parsed


def _grade_humidity(value, warn, crit):
    """Grade a humidity value against upper warn/crit thresholds.

    warn/crit may be None (not configured). Higher is worse.
    """
    state = "OK"
    if crit != None and value >= crit:
        state = "CRIT"
    elif warn != None and value >= warn:
        state = "WARN"
    return state


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.46501.6.2.1"
    item = params.get("item", "")
    check_type = params.get("check_type", "humidity")

    if params.get("_discover"):
        if not _probe_product_exists(ctx, host, community):
            return {"changed": False, "msg": "no Didactum device found",
                    "data": {"discovery": []}}
        section = _build_section(ctx, host, community, base)
        discovery = []
        sensors = section.get(check_type, {})
        for sensor_name, attrs in sensors.items():
            state_readable = attrs.get("state_readable", "")
            if state_readable not in ("off", "not connected"):
                discovery.append({
                    "item": sensor_name,
                    "params": {},
                    "metrics": ["humidity"],
                })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # CHECK MODE -----------------------------------------------------
    if not _probe_product_exists(ctx, host, community):
        return {
            "changed": False,
            "msg": "no Didactum device found at %s" % host,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    section = _build_section(ctx, host, community, base)
    sensors = section.get(check_type, {})
    data = sensors.get(item)
    if data == None:
        return {
            "changed": False,
            "msg": "no such sensor: %s" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    value = data.get("value")
    state_readable = data.get("state_readable", "")
    if state_readable in ("off", "not connected"):
        return {
            "changed": False,
            "msg": "sensor %s not connected" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # Thresholds: params default to Checkmk humidity ruleset defaults.
    # The original check_default_parameters={} means no default levels.
    # Use common humidity defaults when not provided by the operator.
    warn = params.get("levels")
    if warn == None:
        warn = params.get("warn")
    crit = params.get("crit")
    if warn == None and params.get("levels") == None:
        # Checkmk humidity default levels: warn 55%, crit 60% (not connected handled separately)
        warn = 55
        crit = 60
    if crit == None:
        crit = params.get("crit", 60)
    if warn == None:
        warn = params.get("warn", 55)

    # The sensor's own dev_levels override params when available, mirroring
    # check_humidity which accepts dev_levels from the device.
    dev_levels = data.get("levels")
    if dev_levels != None:
        warn = dev_levels[0]
        crit = dev_levels[1]
    dev_levels_lower = data.get("levels_lower")

    # Determine the effective value for grading.
    if type(value) == "int" or type(value) == "float":
        v = value
        state = _grade_humidity(v, warn, crit)
        # If the device reports a non-OK state itself (e.g. alarm), honor it.
        dev_state = data.get("state", 3)
        if dev_state == 2:
            state = "CRIT"
        elif dev_state == 1:
            if state == "OK":
                state = "WARN"
        metrics = {"humidity": v}
        details = "Status: %s" % state_readable
        msg = "Humidity CAN %s: %s%% (%s)" % (item, v, state_readable)
    else:
        # value is a string (unexpected); report UNKNOWN
        msg = "sensor %s returned non-numeric value: %s" % (item, value)
        return {
            "changed": False,
            "msg": msg,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": details,
        },
    }