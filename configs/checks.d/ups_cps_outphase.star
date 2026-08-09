# ===== translated from checkmk.ups_cps_outphase =====
# Library elphase is reproduced inline (no Checkmk runtime available).

# Default threshold levels for each measurable field.
# check_elphase (lib) uses check_levels_legacy_compatible with these defaults.
DEFAULT_LEVELS = {
    "voltage":      (None, None, None, None),   # upper, lower tuples unused here
    "frequency":    (None, None, None, None),
    "output_load":  (None, None, None, None),
    "current":      (None, None, None, None),
}

# Per-field render helpers / units (mirrors elphase check_levels calls).
FIELD_UNITS = {
    "voltage":     "V",
    "frequency":   "Hz",
    "output_load": "%",
    "current":     "A",
}

# Whether the level is "upper" (high-warn) or "lower" (low-warn) sense.
# In the elphase library the defaults come from the ruleset; Checkmk default
# parameters are empty here ({}) so we use None (no levels) like the source.


def _snmp_get(ctx, params, oid):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc == 127:
        fail("snmpget not installed")
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _snmp_walk(ctx, params, oid):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc == 127:
        fail("snmpwalk not installed")
    if res.rc != 0 or not res.stdout:
        return []
    rows = []
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        rows.append((line[:sp], line[sp + 1:].strip()))
    return rows


def _level_state(value, warn_upper, crit_upper, warn_lower, crit_lower):
    # Upper levels (high values bad): warn at >= warn, crit at >= crit.
    if crit_upper != None and value >= crit_upper:
        return "CRIT", "above critical"
    if warn_upper != None and value >= warn_upper:
        return "WARN", "above warning"
    # Lower levels (low values bad): warn at <= warn, crit at <= crit.
    if crit_lower != None and value <= crit_lower:
        return "CRIT", "below critical"
    if warn_lower != None and value <= warn_lower:
        return "WARN", "below warning"
    return "OK", ""


def _check_field(value, levels, unit):
    warn_upper, crit_upper, warn_lower, crit_lower = levels
    state, reason = _level_state(value, warn_upper, crit_upper,
                                 warn_lower, crit_lower)
    return state, reason, unit


def _build_phase(ctx, params, base):
    # Fetch the 4 OIDs (.1 voltage, .2 frequency, .3 output_load, .4 current)
    v = _snmp_get(ctx, params, base + ".1")
    f = _snmp_get(ctx, params, base + ".2")
    lo = _snmp_get(ctx, params, base + ".3")
    c = _snmp_get(ctx, params, base + ".4")
    if v == None or f == None or lo == None or c == None:
        return None
    return {
        "voltage": float(v) / 10,
        "frequency": float(f) / 10,
        "output_load": float(lo),
        "current": float(c) / 10,
    }


def _detect_cps(ctx, params):
    # DETECT_UPS_CPS = startswith(".1.3.6.1.2.1.1.2.0", ".1.3.6.1.4.1.3808.1.1.1")
    sys_oid = _snmp_get(ctx, params, ".1.3.6.1.2.1.1.2.0")
    if sys_oid == None:
        return False
    return sys_oid.startswith(".1.3.6.1.4.1.3808.1.1.1")


def main(ctx, params):
    base = ".1.3.6.1.4.1.3808.1.1.1.4.2"

    if params.get("_discover"):
        # Detection: verify this is a CPS UPS via sysObjectID.
        if not _detect_cps(ctx, params):
            return {"changed": False, "msg": "not a CPS UPS",
                    "data": {"discovery": []}}
        phase = _build_phase(ctx, params, base)
        if phase == None:
            return {"changed": False, "msg": "no outphase data",
                    "data": {"discovery": []}}
        # Single phase per UPS (parse uses string_table[0], item "1").
        return {"changed": False, "msg": "discovered 1 output phase",
                "data": {"discovery": [
                    {"item": "1", "params": {},
                     "metrics": ["voltage", "frequency", "output_load", "current"]},
                ]}}

    # CHECK MODE
    if not _detect_cps(ctx, params):
        return {"changed": False, "msg": "not a CPS UPS",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    phase = _build_phase(ctx, params, base)
    if phase == None:
        return {"changed": False, "msg": "no outphase data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    item = params.get("item", "1")
    if item != "1":
        return {"changed": False, "msg": "unknown phase item " + str(item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    worst = "OK"
    details_parts = []
    metrics = {}

    fields = ["voltage", "frequency", "output_load", "current"]
    levels_in = params.get("levels", {})
    for field in fields:
        value = phase[field]
        levels = levels_in.get(field, DEFAULT_LEVELS[field])
        lv_warn_upper, lv_crit_upper, lv_warn_lower, lv_crit_lower = levels
        unit = FIELD_UNITS[field]
        state, reason = _level_state(
            value, lv_warn_upper, lv_crit_upper,
            lv_warn_lower, lv_crit_lower,
        )
        if state == "CRIT" and worst != "CRIT":
            worst = "CRIT"
        elif state == "WARN" and worst == "OK":
            worst = "WARN"
        metrics[field] = value
        disp = "%s %f%s" % (field, value, unit)
        if state != "OK":
            disp = disp + " " + state + " (" + reason + ")"
        details_parts.append(disp)

    summary = "; ".join(details_parts)
    return {"changed": False, "msg": summary,
            "data": {"state": worst, "metrics": metrics,
                     "details": summary}}