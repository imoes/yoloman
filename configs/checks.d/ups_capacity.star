UPS_OID_BASE = ".1.3.6.1.2.1.33.1.2"
UPS_CAPACITY_COL_REMAINING = UPS_OID_BASE + ".3.0"
UPS_CAPACITY_COL_CHARGE = UPS_OID_BASE + ".4.0"
UPS_SECONDS_COL = UPS_OID_BASE + ".2.0"
UPS_SYS_OID = ".1.3.6.1.2.1.1.2.0"

SUPPORTED_ENTERPRISES = [
    ".1.3.6.1.4.1.232.165.3",
    ".1.3.6.1.4.1.476.1.42",
    ".1.3.6.1.4.1.534.1",
    ".1.3.6.1.4.1.935",
    ".1.3.6.1.4.1.8072.3.2.10",
    ".1.3.6.1.4.1.2254.2.5",
    ".1.3.6.1.4.1.12551.4.0",
    ".1.3.6.1.4.1.43943",
    ".1.3.6.1.4.1.4555.1.1.7",
    ".1.3.6.1.4.1.42610.1.4.4",
]

SUPPORTED_PREFIXES = [
    ".1.3.6.1.4.1.850",
    ".1.3.6.1.4.1.534",
    ".1.3.6.1.4.1.534.2",
    ".1.3.6.1.4.1.5491",
    ".1.3.6.1.4.1.705.1",
    ".1.3.6.1.4.1.818.1.100.1",
    ".1.3.6.1.4.1.935",
    ".1.3.6.1.4.1.534.10",
    ".1.3.6.1.2.1.33",
]


def _sys_oid(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, UPS_SYS_OID],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _is_supported_ups(ctx, params):
    sys_oid = _sys_oid(ctx, params)
    if sys_oid == None:
        return False
    for oid in SUPPORTED_ENTERPRISES:
        if sys_oid == oid:
            return True
    for prefix in SUPPORTED_PREFIXES:
        if sys_oid.startswith(prefix):
            return True
    return False


def _snmp_get(ctx, params, oid):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _optional_int(value):
    if value == None:
        return None
    stripped = value.strip()
    if stripped == "":
        return None
    neg = stripped.startswith("-")
    digits = stripped[1:] if neg else stripped
    if digits == "" or not digits.isdigit():
        return None
    num = int(digits)
    return -num if neg else num


def _render_timespan(seconds):
    if seconds == None:
        return "N/A"
    if seconds == 0:
        return "0s"
    days = seconds // 86400
    remainder = seconds % 86400
    hours = remainder // 3600
    remainder = remainder % 3600
    minutes = remainder // 60
    secs = remainder % 60
    parts = []
    if days > 0:
        parts.append("%dd" % days)
    if hours > 0 or days > 0:
        parts.append("%dh" % hours)
    if minutes > 0 or hours > 0 or days > 0:
        parts.append("%dm" % minutes)
    parts.append("%ds" % secs)
    return " ".join(parts)


def _render_percent(value):
    if value == None:
        return "N/A"
    return "%d%%" % value


def _level_state_lower(value, levels):
    if value == None:
        return "OK"
    warn = levels[0]
    crit = levels[1]
    if crit > 0 and value <= crit:
        return "CRIT"
    if warn > 0 and value <= warn:
        return "WARN"
    return "OK"


def _overall_state(states):
    worst = "OK"
    for s in states:
        if s == "CRIT":
            return "CRIT"
        if s == "WARN" and worst != "CRIT":
            worst = "WARN"
        if s == "UNKNOWN":
            if worst == "OK":
                worst = "UNKNOWN"
    return worst


def main(ctx, params):
    if params.get("_discover"):
        if not _is_supported_ups(ctx, params):
            return {"changed": False, "msg": "no supported UPS found", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 battery capacity service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {
                            "battime": (0, 0),
                            "capacity": (95, 90),
                        },
                        "metrics": ["battery_seconds_remaining", "battery_capacity"],
                    }
                ],
            },
        }

    item = params.get("item", "")
    if item != "":
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if not _is_supported_ups(ctx, params):
        return {
            "changed": False,
            "msg": "no supported UPS found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    seconds_left = _optional_int(_snmp_get(ctx, params, UPS_CAPACITY_COL_REMAINING))
    if seconds_left != None:
        seconds_left = seconds_left * 60
    percent_charged = _optional_int(_snmp_get(ctx, params, UPS_CAPACITY_COL_CHARGE))
    seconds_on_bat = _optional_int(_snmp_get(ctx, params, UPS_SECONDS_COL))

    on_battery = False
    if seconds_on_bat != None and seconds_on_bat > 0:
        on_battery = True

    states = []
    summaries = []

    battime_levels = params.get("battime", (0, 0))
    capacity_levels = params.get("capacity", (95, 90))

    if seconds_left != None:
        ignore = (seconds_left == 0) and not on_battery
        if not ignore:
            st = _level_state_lower(seconds_left, (battime_levels[0] * 60, battime_levels[1] * 60))
            states.append(st)
            summaries.append("Time remaining: " + _render_timespan(seconds_left))
    else:
        states.append("OK")

    if percent_charged != None:
        st = _level_state_lower(percent_charged, capacity_levels)
        states.append(st)
        summaries.append("Capacity: " + _render_percent(percent_charged))
    else:
        states.append("OK")

    if seconds_on_bat != None and seconds_on_bat > 0:
        states.append("OK")
        summaries.append("On battery for " + _render_timespan(seconds_on_bat))
    else:
        if not on_battery:
            states.append("OK")
            summaries.append("On mains")

    metrics = {}
    if seconds_left != None:
        metrics["battery_seconds_remaining"] = seconds_left
    if percent_charged != None:
        metrics["battery_capacity"] = percent_charged
    if seconds_on_bat != None and seconds_on_bat > 0:
        metrics["battery_seconds_on_battery"] = seconds_on_bat

    final_state = _overall_state(states)
    msg = ", ".join(summaries) if summaries else "Battery capacity checked"

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": final_state,
            "metrics": metrics,
            "details": msg,
        },
    }