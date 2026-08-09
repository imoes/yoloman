# ===== checkmk.infoblox_temp → read-only Starlark check module =====
# Source: Checkmk check mk.infoblox_temp (SNMP, IB-PLATFORMONE-MIB temperature sensors)
# Translated for the yolo-man agent Starlark runtime.

# State code mapping (from the Checkmk parse function)
# SNMP value -> (numeric devstate, name)
_STATES = {
    "1": (0, "working"),
    "2": (1, "warning"),
    "3": (2, "failed"),
    "4": (1, "inactive"),
    "5": (3, "unknown"),
}

# SNMP OIDs
_SYS_DESCR_OID = ".1.3.6.1.4.1.7779.3.1.1.2.1.7"
_STATUS_BASE = ".1.3.6.1.4.1.7779.3.1.1.2.1.10.1.2"
_TEMP_BASE = ".1.3.6.1.4.1.7779.3.1.1.2.1.10.1.3"
_SYSOID_OID = ".1.3.6.1.2.1.1.2.0"
_SYSDESCR_OID = ".1.3.6.1.2.1.1.1.0"

# The five sensor columns, in order: cpu1, cpu2, sys, plus two trailing
# columns (.37, .38) that exist in the table but are not temperature sensors.
_SENSOR_OID_SUFS = ["37", "38", "39", "40", "41"]


def _parse_version(version_raw):
    parts = version_raw.split(".")
    major = 0
    minor = 0
    if len(parts) >= 1 and parts[0].isdigit():
        major = int(parts[0])
    if len(parts) >= 2 and parts[1].isdigit():
        minor = int(parts[1])
    return major, minor


def _snmp_get(ctx, oid, community, host):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0 or res.stdout == "":
        return None
    val = res.stdout.strip()
    if val.startswith('"') and val.endswith('"') and len(val) >= 2:
        val = val[1:-1]
    return val


def _snmp_walk(ctx, base, community, host):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base],
        mutates=False,
    )
    out = {}
    if res.rc != 0 or res.stdout == "":
        return out
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        full_oid = line[:sp]
        value = line[sp + 1:]
        suffix = full_oid[len(base) + 1:] if full_oid.startswith(base + ".") else ""
        out[suffix] = value
    return out


def _parse_section(ctx, community, host):
    version_raw = _snmp_get(ctx, _SYS_DESCR_OID + ".0", community, host)
    if version_raw == None or version_raw == "":
        return None

    major, minor = _parse_version(version_raw)

    status_vals = {}
    temp_vals = {}
    for suf in _SENSOR_OID_SUFS:
        s = _snmp_get(ctx, _STATUS_BASE + "." + suf, community, host)
        t = _snmp_get(ctx, _TEMP_BASE + "." + suf, community, host)
        if s != None:
            status_vals[suf] = s
        if t != None:
            temp_vals[suf] = t

    # The Checkmk code indexes: string_table[1][0][1:4] or [3:] depending on
    # version. Both effectively target cpu1(.39), cpu2(.40), sys(.41).
    suffixes = ["39", "40", "41"]

    state_table = [status_vals.get(s, "5") for s in suffixes]
    temp_table = [temp_vals.get(s, "") for s in suffixes]

    return _parse_infoblox_temp(state_table, temp_table)


def _parse_infoblox_temp(state_table, temp_table):
    parsed = {}
    names = ["1", "2", ""]
    for index, state, descr in zip(names, state_table, temp_table):
        if descr == None or ":" not in descr:
            continue
        name, val_str = descr.split(":", 1)
        parts = val_str.strip().split()
        if len(parts) < 2:
            continue
        r_val = parts[0]
        unit = parts[1]
        r_val_clean = r_val.lstrip("+")
        if not _is_float(r_val_clean):
            continue
        val = float(r_val_clean)
        what_name = (name + " " + index).strip()
        st = _STATES.get(state, "5")
        parsed.setdefault(what_name, {
            "state": st,
            "reading": val,
            "unit": unit.lower(),
        })
    return parsed


def _is_float(s):
    if s == None or s == "":
        return False
    # Guard: try float conversion without try/except by validating char-by-char
    # Allow leading + or -, digits, one optional dot
    if len(s) == 0:
        return False
    start = 0
    if s[0] == "+" or s[0] == "-":
        start = 1
        if len(s) == 1:
            return False
    has_dot = False
    has_digit = False
    for i in range(start, len(s)):
        ch = s[i]
        if ch >= "0" and ch <= "9":
            has_digit = True
        elif ch == ".":
            if has_dot:
                return False
            has_dot = True
        else:
            return False
    return has_digit


def _grade_temperature(reading, warn, crit):
    if reading >= crit:
        return "CRIT"
    if reading >= warn:
        return "WARN"
    return "OK"


def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")

        sysoid = _snmp_get(ctx, _SYSOID_OID, community, host)
        if sysoid == None:
            return {"changed": False, "msg": "no SNMP response from host", "data": {"discovery": []}}

        is_infoblox = False
        if sysoid != None and sysoid.startswith(".1.3.6.1.4.1.7779.1"):
            is_infoblox = True

        if not is_infoblox:
            descr = _snmp_get(ctx, _SYSDESCR_OID, community, host)
            if descr != None and "infoblox" in descr.lower():
                is_infoblox = True

        if not is_infoblox:
            return {"changed": False, "msg": "not an Infoblox device", "data": {"discovery": []}}

        section = _parse_section(ctx, community, host)
        if section == None or len(section) == 0:
            return {"changed": False, "msg": "no Infoblox temperature sensors found", "data": {"discovery": []}}

        discovery = []
        for name in section:
            discovery.append({
                "item": name,
                "params": {"levels": (40.0, 50.0)},
                "metrics": ["temperature"],
            })

        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(discovery),
            "data": {"discovery": discovery, "host_labels": {"cmk/os_family": "infoblox"}},
        }

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    sysoid = _snmp_get(ctx, _SYSOID_OID, community, host)
    if sysoid == None:
        return {
            "changed": False,
            "msg": "no SNMP response from host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    section = _parse_section(ctx, community, host)
    if section == None or len(section) == 0:
        return {
            "changed": False,
            "msg": "no Infoblox temperature sensors found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sensor = section.get(item)
    if sensor == None:
        return {
            "changed": False,
            "msg": "no such sensor: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    devstate_tuple = sensor["state"]
    devstate = devstate_tuple[0]
    devstatename = devstate_tuple[1]
    reading = sensor["reading"]
    unit = sensor["unit"]

    if devstate == 2 and devstatename == "failed":
        state = "CRIT"
    elif devstate == 1 and devstatename == "warning":
        state = "WARN"
    else:
        levels = params.get("levels", (40.0, 50.0))
        warn = levels[0]
        crit = levels[1]
        state = _grade_temperature(reading, warn, crit)

    metric_name = "temperature"
    summary = "Temperature %s: %f %s" % (item, reading, unit)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {metric_name: reading},
            "details": "devstate=%s reading=%f unit=%s" % (devstatename, reading, unit),
        },
    }