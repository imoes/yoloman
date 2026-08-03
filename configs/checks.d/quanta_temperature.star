# Checkmk check: quanta_temperature — translated to read-only Starlark
# Monitors Quanta device temperature sensors via SNMP.
# Source: cmk/plugins/quanta/agent_based/quanta_temperature.py

_STATUS_MAP = {
    "1": (1, "other"),
    "2": (3, "unknown"),
    "3": (0, "OK"),
    "4": (1, "non critical upper"),
    "5": (2, "critical upper"),
    "6": (2, "non recoverable upper"),
    "7": (1, "non critical lower"),
    "8": (2, "critical lower"),
    "9": (2, "non recoverable lower"),
    "10": (2, "failed"),
}


def _translate_dev_status(status):
    entry = _STATUS_MAP.get(status)
    if entry == None:
        return (3, "unknown[%s]" % status)
    return entry


def _validate_levels(dev_warn, dev_crit):
    if dev_crit and dev_crit != "-99":
        crit = float(dev_crit)
    else:
        crit = None
    if dev_warn and dev_warn != "-99":
        warn = float(dev_warn)
    elif crit != None:
        warn = crit
    else:
        warn = None
    return warn, crit


def _grade_temperature(value, warn, crit, lower_warn, lower_crit):
    if crit != None and value >= crit:
        return "CRIT"
    if warn != None and value >= warn:
        return "WARN"
    if lower_crit != None and value <= lower_crit:
        return "CRIT"
    if lower_warn != None and value <= lower_warn:
        return "WARN"
    return "OK"


def _snmp_get_column(ctx, base, col, community, host):
    oid = base + "." + col
    res = ctx.run(
        [
            "snmpwalk",
            "-v2c",
            "-c",
            community,
            "-Oqn",
            "-On",
            host,
            oid,
        ],
        mutates=False,
    )
    rows = {}
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        full_oid = parts[0]
        val = parts[1]
        if len(full_oid) <= len(oid) + 1 or full_oid[len(oid)] != ".":
            continue
        index = full_oid[len(oid) + 1:]
        rows[index] = val
    return rows


def _fetch_all_columns(ctx, base, community, host):
    index_col = _snmp_get_column(ctx, base, "1", community, host)
    status_col = _snmp_get_column(ctx, base, "2", community, host)
    name_col = _snmp_get_column(ctx, base, "3", community, host)
    value_col = _snmp_get_column(ctx, base, "4", community, host)
    upper_crit_col = _snmp_get_column(ctx, base, "6", community, host)
    upper_warn_col = _snmp_get_column(ctx, base, "7", community, host)
    lower_warn_col = _snmp_get_column(ctx, base, "8", community, host)
    lower_crit_col = _snmp_get_column(ctx, base, "9", community, host)
    return {
        "index": index_col,
        "status": status_col,
        "name": name_col,
        "value": value_col,
        "upper_crit": upper_crit_col,
        "upper_warn": upper_warn_col,
        "lower_warn": lower_warn_col,
        "lower_crit": lower_crit_col,
    }


def _build_names(name_col, index_col):
    names = {}
    for idx in index_col:
        name_val = name_col.get(idx, "")
        name_clean = name_val.replace("\x01", "")
        names[idx] = name_clean
    return names


def _safe_float(s):
    s = str(s).strip()
    if s and s != "-99":
        parts = s.split(".")
        valid = True
        if len(parts) == 1:
            valid = parts[0].isdigit() or (parts[0].startswith("-") and parts[0][1:].isdigit())
        elif len(parts) == 2:
            left = parts[0]
            left_ok = left.isdigit() or (left.startswith("-") and left[1:].isdigit())
            valid = left_ok and parts[1].isdigit()
        else:
            valid = False
        if valid:
            return float(s)
    return None


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    warn = params.get("warn")
    crit = params.get("crit")

    base = ".1.3.6.1.4.1.7244.1.2.1.3.4.1"

    # Detection: check for Quanta enterprise MIB + specific OID presence
    sys_oid_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sys_oid_res.rc == 127:
        return {
            "changed": False,
            "msg": "snmp not available",
            "data": {"discovery": []},
        }
    if sys_oid_res.rc != 0 or not sys_oid_res.stdout.strip():
        return {
            "changed": False,
            "msg": "not a Quanta device",
            "data": {"discovery": []},
        }
    sys_oid = sys_oid_res.stdout.strip()
    if not sys_oid.startswith(".1.3.6.1.4.1.8072.3.2.10"):
        return {
            "changed": False,
            "msg": "not a Quanta device",
            "data": {"discovery": []},
        }

    detect_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.7244.1.2.1.1.1.0"],
        mutates=False,
    )
    if detect_res.rc != 0:
        return {
            "changed": False,
            "msg": "not a Quanta device",
            "data": {"discovery": []},
        }

    if params.get("_discover"):
        cols = _fetch_all_columns(ctx, base, community, host)
        names = _build_names(cols["name"], cols["index"])

        items = []
        seen = {}
        for idx in cols["index"]:
            name = names[idx]
            if name in seen:
                continue
            seen[name] = True
            items.append(
                {
                    "item": name,
                    "params": {
                        "warn": warn if warn != None else 70,
                        "crit": crit if crit != None else 80,
                    },
                    "metrics": ["temperature"],
                }
            )
        return {
            "changed": False,
            "msg": "discovered %d items" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")

    cols = _fetch_all_columns(ctx, base, community, host)
    names = _build_names(cols["name"], cols["index"])

    target_idx = None
    for idx in cols["index"]:
        if names[idx] == item:
            target_idx = idx
            break

    if target_idx == None:
        return {
            "changed": False,
            "msg": "no such sensor: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    dev_status_str = cols["status"].get(target_idx, "2")
    status_state, status_name = _translate_dev_status(dev_status_str)

    dev_value_str = cols["value"].get(target_idx, "")
    value = _safe_float(dev_value_str)

    upper_crit_str = cols["upper_crit"].get(target_idx, "-99")
    upper_warn_str = cols["upper_warn"].get(target_idx, "-99")
    lower_warn_str = cols["lower_warn"].get(target_idx, "-99")
    lower_crit_str = cols["lower_crit"].get(target_idx, "-99")

    upper_warn, upper_crit = _validate_levels(upper_warn_str, upper_crit_str)
    lower_warn, lower_crit = _validate_levels(lower_warn_str, lower_crit_str)

    if value == None:
        state = "OK" if status_state == 0 else ("WARN" if status_state == 1 else ("CRIT" if status_state == 2 else "UNKNOWN"))
        if status_state == 3:
            state = "UNKNOWN"
        return {
            "changed": False,
            "msg": "Status: %s" % status_name,
            "data": {
                "state": state,
                "metrics": {},
                "details": "sensor %s reports status %s" % (item, status_name),
            },
        }

    # Use operator-provided levels if available, otherwise device levels
    op_warn = params.get("warn")
    op_crit = params.get("crit")
    if op_warn != None and op_crit != None:
        state = _grade_temperature(value, op_warn, op_crit, None, None)
    else:
        state = _grade_temperature(value, upper_warn, upper_crit, lower_warn, lower_crit)

    # Device status overrides if critical
    if status_state == 2:
        state = "CRIT"
    elif status_state == 3:
        state = "UNKNOWN"

    return {
        "changed": False,
        "msg": "Temperature %s: %f C" % (item, value),
        "data": {
            "state": state,
            "metrics": {"temperature": value},
            "details": "sensor %s: %f C (status: %s)" % (item, value, status_name),
        },
    }