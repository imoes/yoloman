# Checkmk check: liebert_fans_condenser → read-only Starlark check module
#
# SNMP-based check. The monitored product is a Liebert HVAC device queried over
# SNMP. The host running this check must have the device reachable; there is
# no on-host proxy for a remote SNMP appliance, so the device MUST be present
# (probe via SNMP sysObjectID). Absence → empty discovery / UNKNOWN.

DEFAULT_LEVELS_UPPER = (80.0, 90.0)

# SNMP base for the Liebert fans condenser section.
LIEBERT_BASE_OID = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
LIEBERT_SYSOID = ".1.3.6.1.2.1.1.2.0"
LIEBERT_ENTERPRISE_PREFIX = ".1.3.6.1.4.1.476.1.42"

# Column OIDs within the base: name/value/unit triples.
COL_NAME = "10.1.2.1.5276"
COL_VALUE = "20.1.2.1.5276"
COL_UNIT = "30.1.2.1.5276"


def _snmp_get_scalar(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc == 127:
        fail("snmpget not installed on the monitoring host")
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _snmp_walk(ctx, host, community, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc == 127:
        fail("snmpwalk not installed on the monitoring agent host")
    if res.rc != 0:
        return []
    return res.stdout.splitlines()


def _walk_column(ctx, host, community, column_oid):
    """Return {index: (name, value_str, unit)} by walking name/value/unit columns."""
    names = {}
    vals = {}
    units = {}
    name_oid = column_oid + "." + COL_NAME
    val_oid = column_oid + "." + COL_VALUE
    unit_oid = column_oid + "." + COL_UNIT

    for line in _snmp_walk(ctx, host, community, name_oid):
        sp = line.find(" ")
        if sp < 0:
            continue
        full_oid = line[:sp]
        idx = full_oid[len(name_oid) + 1:]
        names[idx] = line[sp + 1:]

    for line in _snmp_walk(ctx, host, community, val_oid):
        sp = line.find(" ")
        if sp < 0:
            continue
        full_oid = line[:sp]
        idx = full_oid[len(val_oid) + 1:]
        vals[idx] = line[sp + 1:]

    for line in _snmp_walk(ctx, host, community, unit_oid):
        sp = line.find(" ")
        if sp < 0:
            continue
        full_oid = line[:sp]
        idx = full_oid[len(unit_oid) + 1:]
        units[idx] = line[sp + 1:]

    out = {}
    for idx in names:
        if idx in vals and idx in units:
            out[idx] = (names[idx], vals[idx], units[idx])
    return out


def _detect_liebert(ctx, host, community):
    sysoid = _snmp_get_scalar(ctx, host, community, LIEBERT_SYSOID)
    if sysoid == None:
        return False
    return sysoid.startswith(LIEBERT_ENTERPRISE_PREFIX)


def _grade_levels(value, warn, crit):
    if value == None:
        return "UNKNOWN"
    if warn != None and crit != None:
        if value >= crit:
            return "CRIT"
        if value >= warn:
            return "WARN"
    return "OK"


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe for the real thing: a Liebert device must be reachable and
    # identify itself as such. Absence is an answer, not an error.
    if not _detect_liebert(ctx, host, community):
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "no Liebert device found at %s" % host,
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "no Liebert device found at %s" % host,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Liebert enterprise OID not detected at %s" % host,
            },
        }

    # Fetch name/value/unit columns and correlate by index.
    rows = _walk_column(ctx, host, community, LIEBERT_BASE_OID)

    if params.get("_discover"):
        discovery = []
        for idx in sorted(rows):
            name, val_str, unit = rows[idx]
            if name == "" or name == None:
                continue
            # Guard instead of try/except: only proceed on parseable floats.
            if val_str == "" or val_str == None or not _is_float(val_str):
                continue
            discovery.append({
                "item": name,
                "params": {
                    "levels": params.get("levels", DEFAULT_LEVELS_UPPER),
                    "levels_lower": params.get("levels_lower", None),
                },
                "metrics": ["fan_perc"],
            })
        return {
            "changed": False,
            "msg": "discovered %d fan items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode: grade one item (named by params) using SNMP index lookup.
    item = params.get("item", "")

    target_idx = None
    for idx in rows:
        name = rows[idx][0]
        if name == item:
            target_idx = idx
            break

    if target_idx == None:
        return {
            "changed": False,
            "msg": "no such fan item: %s" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "fan item '%s' not present on Liebert device at %s" % (item, host),
            },
        }

    name, val_str, unit = rows[target_idx]
    if val_str == "" or val_str == None:
        return {
            "changed": False,
            "msg": "empty value for %s" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "no value reported for fan '%s'" % item,
            },
        }

    # Guard instead of try/except: validate before parsing.
    if not _is_float(val_str):
        return {
            "changed": False,
            "msg": "non-numeric value for %s: %s" % (item, val_str),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "cannot parse fan value '%s' as float" % val_str,
            },
        }
    value = float(val_str)

    levels = params.get("levels", DEFAULT_LEVELS_UPPER)
    levels_lower = params.get("levels_lower", None)
    warn = levels[0] if len(levels) >= 1 else None
    crit = levels[1] if len(levels) >= 2 else None

    state = _grade_levels(value, warn, crit)

    return {
        "changed": False,
        "msg": "%s %f %s" % (item, value, unit),
        "data": {
            "state": state,
            "metrics": {"fan_perc": value},
            "details": "Liebert condenser fan '%s' at %s: %f %s" % (item, host, value, unit),
        },
    }


def _is_float(s):
    """Guard helper: True if s parses as a float without try/except."""
    if s == None or s == "":
        return False
    # Accept optional leading sign, digits, optional decimal, optional exponent.
    t = s
    if t[0:1] in ("+", "-"):
        t = t[1:]
    if t == "":
        return False
    if "." in t:
        parts = t.split(".")
        if len(parts) != 2:
            return False
        int_part, frac_part = parts
        if int_part == "" and frac_part == "":
            return False
        if int_part == "" and frac_part != "":
            return _is_digits(frac_part)
        if int_part != "" and frac_part == "":
            return _is_digits(int_part)
        return _is_digits(int_part) and _is_digits(frac_part)
    if "e" in t or "E" in t:
        eidx = -1
        if "e" in t:
            eidx = t.find("e")
        if "E" in t:
            eidx2 = t.find("E")
            if eidx == -1 or (eidx2 != -1 and eidx2 < eidx):
                eidx = eidx2
        if eidx == -1:
            return False
        mantissa = t[:eidx]
        exp = t[eidx + 1:]
        if exp == "" or not _is_int(exp):
            return False
        return _is_float(mantissa)
    return _is_digits(t)


def _is_digits(s):
    if s == "":
        return False
    for c in s:
        if c not in "0123456789":
            return False
    return True


def _is_int(s):
    if s == None or s == "":
        return False
    t = s
    if t[0:1] in ("+", "-"):
        t = t[1:]
    return _is_digits(t)