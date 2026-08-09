# pandacom_fc_temp — read-only Starlark translation of the Checkmk check plugin
# Monitors FC module temperatures on a Pandacom device via SNMP.

# Base OID for the pandacom_fc_temp SNMP table
_PANDACOM_FC_TEMP_BASE = "1.3.6.1.4.1.3652.3.3.3"
# The sysoid prefix that identifies a Pandacom device
_PANDACOM_SYSOID_PREFIX = "1.3.6.1.4.1.3652.3"

# Column sub-OIDs relative to the base (matches oids=["1.1.2","1.1.7","2.1.13","2.1.14"])
_COL_SLOT = ".1.1.2"
_COL_TEMP = ".1.1.7"
_COL_WARN = ".2.1.13"
_COL_CRIT = ".2.1.14"

# Checkmk default temperature thresholds (warn, crit)
_DEFAULT_LEVELS = [35.0, 40.0]


def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)


def _discover(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")

    # Probe for the real thing first: is this a Pandacom device?
    if not _is_pandacom(ctx, host, community, version):
        return {
            "changed": False,
            "msg": "no Pandacom device found",
            "data": {"discovery": []},
        }

    # Walk the slot column to get the list of FC module slots
    rows = _walk_column(ctx, host, community, version, _PANDACOM_FC_TEMP_BASE + _COL_SLOT)
    if rows == None:
        return {
            "changed": False,
            "msg": "no Pandacom FC temp data",
            "data": {"discovery": []},
        }

    discovery = []
    for oid, slot_str in rows:
        discovery.append({
            "item": slot_str,
            "params": {"levels": _DEFAULT_LEVELS},
            "metrics": ["temperature"],
        })

    return {
        "changed": False,
        "msg": "discovered %d FC modules" % len(discovery),
        "data": {"discovery": discovery},
    }


def _check(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")
    item = params.get("item", "")
    levels = params.get("levels", _DEFAULT_LEVELS)
    warn = levels[0] if len(levels) >= 1 else _DEFAULT_LEVELS[0]
    crit = levels[1] if len(levels) >= 2 else _DEFAULT_LEVELS[1]

    # Probe for the real thing
    if not _is_pandacom(ctx, host, community, version):
        return {
            "changed": False,
            "msg": "no Pandacom device found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Read all four columns for this device
    slots = _walk_column(ctx, host, community, version, _PANDACOM_FC_TEMP_BASE + _COL_SLOT)
    temps = _walk_column(ctx, host, community, version, _PANDACOM_FC_TEMP_BASE + _COL_TEMP)
    warns = _walk_column(ctx, host, community, version, _PANDACOM_FC_TEMP_BASE + _COL_WARN)
    crits = _walk_column(ctx, host, community, version, _PANDACOM_FC_TEMP_BASE + _COL_CRIT)

    if slots == None or temps == None or warns == None or crits == None:
        return {
            "changed": False,
            "msg": "could not read Pandacom FC temperature data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Find the slot that matches the requested item, and get its index
    target_oid = None
    for oid, slot_str in slots:
        if slot_str == item:
            target_oid = oid
            break

    if target_oid == None:
        return {
            "changed": False,
            "msg": "no such FC module: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Derive the index from the slot OID
    target_index = _index_of(target_oid, _PANDACOM_FC_TEMP_BASE + _COL_SLOT)
    if target_index == None:
        return {
            "changed": False,
            "msg": "could not determine index for FC module %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Read temperature, warning level, alarm level for that index
    temp_val = _lookup_by_index(temps, target_index)
    warn_val = _lookup_by_index(warns, target_index)
    crit_val = _lookup_by_index(crits, target_index)

    if temp_val == None:
        return {
            "changed": False,
            "msg": "no temperature reading for FC module %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    temp = _to_float(temp_val)
    if temp == None:
        return {
            "changed": False,
            "msg": "invalid temperature value: %s" % temp_val,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Dev levels from the device take precedence when available
    dev_warn = _to_float(warn_val)
    dev_crit = _to_float(crit_val)
    if dev_warn != None and dev_crit != None:
        warn = dev_warn
        crit = dev_crit

    state = _grade(temp, warn, crit)
    detail = "FC Module %s: %f C (warn %f, crit %f)" % (item, temp, warn, crit)

    return {
        "changed": False,
        "msg": detail,
        "data": {
            "state": state,
            "metrics": {"temperature": temp},
            "details": detail,
        },
    }


# ---------------------------------------------------------------------------
# Helpers

def _is_pandacom(ctx, host, community, version):
    """Walk the sysDescr OID .1.3.6.1.2.1.1.2.0 to check the device sysoid."""
    res = ctx.run(
        ["snmpget", "-" + version, "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res.rc != 0:
        return False
    sysoid = _strip_type_tag(res.stdout)
    return sysoid.startswith(_PANDACOM_SYSOID_PREFIX)


def _walk_column(ctx, host, community, version, column_oid):
    """snmpwalk a column OID with -Oqn; returns list of (oid, value) or None on failure."""
    res = ctx.run(
        ["snmpwalk", "-" + version, "-c", community, "-Oqn", host, column_oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    rows = []
    for line in res.stdout.splitlines():
        # Each line: "<oid> <value>"
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        rows.append((parts[0], parts[1]))
    return rows


def _index_of(oid, column_oid):
    """Return the index suffix of oid after column_oid, or None."""
    prefix = column_oid + "."
    if not oid.startswith(prefix):
        return None
    return oid[len(prefix):]


def _lookup_by_index(rows, index):
    """Find the value in rows whose OID ends with '.' + index."""
    if rows == None:
        return None
    suffix = "." + index
    for oid, val in rows:
        if oid.endswith(suffix):
            return val
    return None


def _to_float(s):
    if s == None:
        return None
    s = s.strip()
    if s == "" or s == "''" or s == '""':
        return None
    # Try integer
    neg = False
    try_val = s
    if try_val.startswith("-"):
        neg = True
        try_val = try_val[1:]
    if try_val.isdigit():
        return float(int(try_val)) * (-1 if neg else 1)
    # Try float with decimal point
    if "." in try_val:
        parts = try_val.split(".", 1)
        if len(parts) == 2:
            int_part = parts[0]
            frac_part = parts[1]
            if int_part.isdigit() and frac_part.isdigit():
                frac_value = 0.0
                divisor = _ten_pow(len(frac_part))
                frac_value = int(frac_part) / divisor
                v = int(int_part) + frac_value
                return v * (-1 if neg else 1)
    return None


def _ten_pow(exp):
    """Compute 10**exp via repeated multiplication (no ** operator)."""
    result = 1.0
    i = 0
    while i < exp:
        result = result * 10.0
        i = i + 1
    return result


def _strip_type_tag(s):
    """Remove SNMP type prefix like 'STRING: ' or 'OID: ' from -Oqv output."""
    s = s.strip()
    pos = s.find(": ")
    if pos >= 0:
        return s[pos + 2:]
    pos = s.find(":")
    if pos >= 0:
        return s[pos + 1:]
    return s


def _grade(value, warn, crit):
    """Upper-level threshold grading: CRIT if >= crit, WARN if >= warn, OK otherwise."""
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"