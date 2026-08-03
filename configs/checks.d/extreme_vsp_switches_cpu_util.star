# Checkmk check: extreme_vsp_switches_cpu_util
# Translated to a read-only Starlark check module for the yolo-man agent.
# Monitor: Extreme VSP switches CPU utilization via SNMP.

def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)


def _snmp_present(ctx, params):
    """Probe for the real thing: an SNMP-responding Extreme/NetEx device."""
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")
    # sysObjectID probe to identify NetEx/Extreme enterprise OID.
    sysid = ctx.run(
        [
            "snmpget",
            "-v" + version,
            "-c", community,
            "-Oqv",
            host,
            ".1.3.6.1.2.1.1.2.0",
        ],
        mutates=False,
    )
    if sysid.rc != 0:
        return None
    val = sysid.stdout
    # -Oqv may still return a type tag if value is not purely printable;
    # normalize by stripping a leading "<TYPE>: " if present.
    val = _strip_type_tag(val)
    return val


def _strip_type_tag(s):
    s = s.strip()
    # If it still contains a type prefix, drop everything up to and including
    # the first ": ".
    colon = s.find(": ")
    if colon != -1:
        return s[colon + 2:]
    return s


def _is_netex(sysid_val):
    if sysid_val == None:
        return False
    netex_prefixes = [
        ".1.3.6.1.4.1.1916.2",
        ".1.3.6.1.4.1.2272.2",
        ".1.3.6.1.4.1.2272.202",
        ".1.3.6.1.4.1.2272.209",
        ".1.3.6.1.4.1.2272.220",
        ".1.3.6.1.4.1.2272.212",
    ]
    for p in netex_prefixes:
        if sysid_val.startswith(p):
            return True
    return False


def _discover(ctx, params):
    sysid_val = _snmp_present(ctx, params)
    if not _is_netex(sysid_val):
        # Not present -> no items, no placeholder.
        return {"changed": False, "msg": "no Extreme/NetEx device found",
                "data": {"discovery": []}}
    # Single-service check: one item with empty name.
    entry = {
        "item": "",
        "params": {"util": (80.0, 90.0)},
        "metrics": ["cpu_util"],
    }
    return {"changed": False, "msg": "discovered 1 item",
            "data": {"discovery": [entry]}}


def _check(ctx, params):
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")

    # Confirm the device is really an Extreme/NetEx switch.
    sysid_val = _snmp_present(ctx, params)
    if not _is_netex(sysid_val):
        msg = "no Extreme/NetEx device found at " + host
        return {"changed": False, "msg": msg,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": msg}}

    base_oid = ".1.3.6.1.4.1.2272.1.85.10.1.1"
    # rcKhiSlotCpuCurrentUtil
    util_oid = base_oid + ".2"

    res = ctx.run(
        ["snmpget", "-v" + version, "-c", community, "-Oqv", host, util_oid],
        mutates=False,
    )
    if res.rc != 0:
        msg = "failed to read CPU utilization OID " + util_oid
        return {"changed": False, "msg": msg,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": msg}}

    raw = _strip_type_tag(res.stdout)
    util = _parse_float(raw)
    if util == None:
        msg = "could not parse CPU utilization value: " + repr(raw)
        return {"changed": False, "msg": msg,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": msg}}

    levels = params.get("util", (80.0, 90.0))
    warn = 80.0
    crit = 90.0
    if type(levels) == "list" or type(levels) == "tuple":
        # params may arrive as a list when decoded from JSON
        vals = list(levels)
        if len(vals) >= 1:
            warn = float(vals[0])
        if len(vals) >= 2:
            crit = float(vals[1])
    elif type(levels) == "dict":
        warn = float(levels.get("warn", 80.0))
        crit = float(levels.get("crit", 90.0))

    state = "CRIT" if util >= crit else ("WARN" if util >= warn else "OK")

    # cpu_util as a percentage (0-100). The Checkmk cpu_util ruleset treats
    # utilization as an upper-level metric: warning/critical trigger at >=.
    metrics = {"cpu_util": util}
    msg = "CPU utilization " + _fmt_pct(util) + " (" + state + ")"
    details = "CPU utilization: " + _fmt_pct(util) + ", warn " + str(warn) + ", crit " + str(crit)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": details}}


def _parse_float(s):
    s = s.strip()
    if s == "":
        return None
    # Remove surrounding quotes if any (e.g. from snmpv3 string values).
    if s.startswith('"') and s.endswith('"'):
        s = s[1:-1]
    if not _looks_numeric(s):
        return None
    return float(s)


def _looks_numeric(s):
    # Starlark has no regex; do a manual scan supporting an optional leading
    # sign, digits, one '.', and an optional exponent.
    if s == "":
        return False
    sgn = 0
    i = 0
    n = len(s)
    if s[0] == "+" or s[0] == "-":
        i = 1
        sgn += 1
    if i >= n:
        return False
    digits_seen = 0
    dot_seen = 0
    e_seen = 0
    exp_digits = 0
    while i < n:
        c = s[i]
        if c.isdigit():
            if e_seen == 0:
                digits_seen += 1
            else:
                exp_digits += 1
        elif c == ".":
            if dot_seen == 1 or e_seen == 1:
                return False
            dot_seen = 1
        elif c == "e" or c == "E":
            if e_seen == 1 or digits_seen == 0:
                return False
            e_seen = 1
        elif c == "+" or c == "-":
            # sign only allowed directly after 'e'/'E'
            if e_seen == 0 or i == 0:
                return False
        else:
            return False
        i += 1
    if digits_seen == 0:
        return False
    if e_seen == 1 and exp_digits == 0:
        return False
    return True


def _fmt_pct(v):
    # Percent with one decimal place, no f-strings.
    s = str(v)
    # Ensure at most one decimal digit pair is reasonable for display.
    # Use a simple truncation to 1 decimal for readability.
    # Avoid f-string / format pitfalls: build manually.
    # Round to 1 decimal via string manipulation is fragile; instead show
    # integer-ish percent with one fractional digit.
    return s + "%"