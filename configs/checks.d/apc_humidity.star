# Translated from Checkmk check: checkmk.apc_humidity
# Check: Humidity sensors on APC ATS devices, read via SNMP.
# Read-only Starlark check module for the yolo-man agent.

# OID base for the APC humidity table (.1.3.6.1.4.1.318.1.1.10.4.2.3.1)
APC_HUMIDITY_BASE = ".1.3.6.1.4.1.318.1.1.10.4.2.3.1"
# Column OIDs (suffixes off base)
COL_NAME = "3"   # sensor name
COL_VALUE = "6"  # humidity value (%)

# Default thresholds (Checkmk check_default_parameters for "humidity" ruleset)
DEFAULT_LEVELS = (60.0, 65.0)
DEFAULT_LEVELS_LOWER = (40.0, 35.0)


def _is_apc_host(ctx, host, community):
    """Establishes that this host is an APC device via sysObjectID.
    Returns True if the sysOID starts with the APC enterprise prefix,
    False on any failure (including rc==127 meaning snmp not installed)."""
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res.rc != 0:
        return False
    return res.stdout.strip().startswith(".1.3.6.1.4.1.318")


def _walk_table(ctx, host, community, column_oid):
    """Walk a table column with -Oqn => lines of '<full-col-oid>.<index> <value>'.
    Returns list of (index, value) where index is the OID suffix after column base."""
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid],
        mutates=False,
    )
    rows = []
    if res.rc != 0:
        return rows
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        full_oid = line[:sp]
        value = line[sp + 1:]
        idx = full_oid[len(column_oid) + 1:]
        if idx == "":
            continue
        rows.append((idx, value))
    return rows


def _get_scalar(ctx, host, community, oid):
    """Read a scalar via snmpget -Oqv (bare value). Returns stripped stdout or empty on failure."""
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return ""
    return res.stdout.strip()


def _to_float(s):
    """Convert a string to float, returning None on failure (guard, not try)."""
    if s == "" or s == None:
        return None
    # Guard: attempt float conversion; if value is numeric return it.
    # Starlark has no try, so validate with a manual check.
    if s.startswith("-"):
        body = s[1:]
    else:
        body = s
    if body == "" or body == ".":
        return None
    seen_dot = False
    for ch in body:
        if ch == ".":
            if seen_dot:
                return None
            seen_dot = True
        elif ch < "0" or ch > "9":
            return None
    return float(s)


def _grade_humidity(value):
    """Apply the humidity ruleset thresholds to a numeric value.
    Upper levels: WARN if value >= warn, CRIT if value >= crit.
    Lower levels: WARN if value <= warn_lower, CRIT if value <= crit_lower."""
    state = "OK"
    if value >= DEFAULT_LEVELS[1]:
        state = "CRIT"
    elif value >= DEFAULT_LEVELS[0]:
        state = "WARN"
    # Lower thresholds may escalate to CRIT.
    if value <= DEFAULT_LEVELS_LOWER[1]:
        state = "CRIT"
    elif value <= DEFAULT_LEVELS_LOWER[0]:
        if state != "CRIT":
            state = "WARN"
    return state


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe: confirm this host is APC (enterprise OID prefix .1.3.6.1.4.1.318)
    if not _is_apc_host(ctx, host, community):
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "host is not an APC device (sysOID not APC enterprise prefix)",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "host is not an APC device (sysOID not APC enterprise prefix)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if params.get("_discover"):
        # Discovery: walk the value column; rows whose value >= 0 yield a Service.
        value_col = APC_HUMIDITY_BASE + "." + COL_VALUE
        rows = _walk_table(ctx, host, community, value_col)
        out = []
        for idx, val in rows:
            num = _to_float(val)
            if num == None:
                continue
            # Checkmk: int(line[1]) >= 0 => yield Service. We accept >= -0.01 to
            # tolerate SNMP quirks but keep numeric validity.
            if num >= 0:
                # Fetch the sensor name for this index for a readable item.
                name_oid = APC_HUMIDITY_BASE + "." + COL_NAME + "." + idx
                name_val = _get_scalar(ctx, host, community, name_oid)
                item_name = name_val if name_val != "" else idx
                out.append({
                    "item": item_name,
                    "params": {
                        "levels": list(DEFAULT_LEVELS),
                        "levels_lower": list(DEFAULT_LEVELS_LOWER),
                    },
                    "metrics": ["humidity"],
                })
        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(out),
            "data": {"discovery": out, "host_labels": {"cmk/vendor": "apc"}},
        }

    # Check mode: evaluate ONE item (params["item"]) by matching its name.
    item = params.get("item", "")
    value_col = APC_HUMIDITY_BASE + "." + COL_VALUE
    rows = _walk_table(ctx, host, community, value_col)

    matched_val = None
    matched_name = None
    for idx, val in rows:
        name_oid = APC_HUMIDITY_BASE + "." + COL_NAME + "." + idx
        name_val = _get_scalar(ctx, host, community, name_oid)
        candidate = name_val if name_val != "" else idx
        if candidate == item:
            matched_val = val
            matched_name = candidate
            break

    if matched_val == None:
        return {
            "changed": False,
            "msg": "no humidity sensor named '%s' found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    num = _to_float(matched_val)
    if num == None:
        return {
            "changed": False,
            "msg": "could not parse humidity value for '%s': %s" % (matched_name, matched_val),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state = _grade_humidity(num)
    msg = "Humidity %s: %f%%" % (matched_name, num)
    if state != "OK":
        msg += " (" + state + ")"
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"humidity": num},
            "details": "",
        },
    }