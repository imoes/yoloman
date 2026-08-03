"""Checkmk check: bluenet_meter (read-only Starlark translation)."""

# OID base for the BlueNet meter table columns.
_METER_BASE = ".1.3.6.1.4.1.21695.1.10.7.2.1"

# sysObjectID prefix that proves this is a BlueNet device.
_SYSOID_PREFIX = ".1.3.6.1.4.1.21695.1"


def _parse_levels(params):
    """Extract (warn, crit) from Checkmk-style level params.

    Accepts either {"warn": w, "crit": c} or
    {"levels": (w, c)} (or a legacy list). Returns
    (None, None) when absent so callers can skip grading.
    """
    if not params:
        return (None, None)
    levels = params.get("levels")
    if levels == None:
        levels = params.get("thresholds")
    if levels != None and type(levels) == "list" and len(levels) >= 2:
        return (float(levels[0]), float(levels[1]))
    warn = params.get("warn")
    crit = params.get("crit")
    if warn != None and crit != None:
        return (float(warn), float(crit))
    return (None, None)


def _grade(value, warn, crit, upper, label):
    """Grade a value against (warn, crit).

    upper=True means rising levels (WARN if >= warn, CRIT if >= crit).
    upper=False means falling levels (WARN if <= warn, CRIT if <= crit).
    Returns ("OK"|"WARN"|"CRIT"|None, label).
    """
    if warn == None or crit == None:
        return (None, "")
    if upper:
        if value >= crit:
            return ("CRIT", label)
        if value >= warn:
            return ("WARN", label)
    else:
        if value <= crit:
            return ("CRIT", label)
        if value <= warn:
            return ("WARN", label)
    return (None, "")


def _fmt(value, decimals):
    """Format a float to a fixed number of decimals using int() rounding."""
    if decimals == 0:
        return str(int(value + 0.5))
    factor = 1
    for _ in range(decimals):
        factor = factor * 10
    rounded = int(value * factor + 0.5) / float(factor)
    return str(rounded)


def _check_elphase(ctx, params, elphase):
    """Reproduce cmk.plugins.lib.elphase.check_elphase for the metrics we have.

    Grades voltage, current, power (active) and appower (apparent) against
    their respective levels and yields Checkmk-style results.
    """
    results = []
    summary = []

    # Voltage (upper levels).
    v = elphase.get("voltage")
    if v != None:
        value = v.get("value")
        if value != None:
            warn, crit = _parse_levels(params.get("voltage"))
            state, suffix = _grade(value, warn, crit, True, "V")
            if state == "CRIT":
                results.append({"state": "CRIT", "msg": "Voltage %s V critical" % str(value)})
            elif state == "WARN":
                results.append({"state": "WARN", "msg": "Voltage %s V warning" % str(value)})
            summary.append("U=" + _fmt(value, 2) + suffix)
            results.append({"metric": "voltage", "value": value})

    # Current (upper levels).
    i = elphase.get("current")
    if i != None:
        value = i.get("value")
        if value != None:
            warn, crit = _parse_levels(params.get("current"))
            state, suffix = _grade(value, warn, crit, True, "A")
            if state == "CRIT":
                results.append({"state": "CRIT", "msg": "Current %s A critical" % str(value)})
            elif state == "WARN":
                results.append({"state": "WARN", "msg": "Current %s A warning" % str(value)})
            summary.append("I=" + _fmt(value, 2) + suffix)
            results.append({"metric": "current", "value": value})

    # Active power (upper levels).
    p = elphase.get("power")
    if p != None:
        value = p.get("value")
        if value != None:
            warn, crit = _parse_levels(params.get("power"))
            state, suffix = _grade(value, warn, crit, True, "W")
            if state == "CRIT":
                results.append({"state": "CRIT", "msg": "Power %s W critical" % str(value)})
            elif state == "WARN":
                results.append({"state": "WARN", "msg": "Power %s W warning" % str(value)})
            summary.append("P=" + _fmt(value, 0) + suffix)
            results.append({"metric": "power", "value": value})

    # Apparent power (upper levels).
    ap = elphase.get("appower")
    if ap != None:
        value = ap.get("value")
        if value != None:
            warn, crit = _parse_levels(params.get("appower"))
            state, suffix = _grade(value, warn, crit, True, "VA")
            if state == "CRIT":
                results.append({"state": "CRIT", "msg": "Apparent power %s VA critical" % str(value)})
            elif state == "WARN":
                results.append({"state": "WARN", "msg": "Apparent power %s VA warning" % str(value)})
            summary.append("S=" + _fmt(value, 0) + suffix)
            results.append({"metric": "appower", "value": value})

    return (summary, results)


def _snmp_get_value(ctx, community, host, oid):
    """Single-value SNMP GET using -Oqv (bare value, no type tag)."""
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    out = res.stdout.strip()
    if out == "":
        return None
    return out


def _snmp_walk(ctx, community, host, oid):
    """Walk a column OID with -Oqn -> list of (full_oid, value) lines."""
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return []
    lines = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        # Format: "<oid> <value>" — split on FIRST space only.
        parts = line.split(" ", 1)
        if len(parts) == 2:
            lines.append((parts[0], parts[1]))
        else:
            lines.append((parts[0], ""))
    return lines


def _is_bluenet(ctx, community, host):
    """Probe sysObjectID to confirm this is a BlueNet device."""
    oid = ".1.3.6.1.2.1.1.2.0"
    val = _snmp_get_value(ctx, community, host, oid)
    if val == None:
        return False
    return val.startswith(_SYSOID_PREFIX)


def _build_section(ctx, community, host):
    """Fetch the meter table and parse it like parse_bluenet_meter.

    Returns a list of dicts: [{"item": <meter_id>, "elphase": {...}}, ...].
    Skips meters with no voltage (u_rms == "0"), mirroring the source.
    """
    col_meter_id = _METER_BASE + ".1"
    col_power_p = _METER_BASE + ".5"
    col_power_s = _METER_BASE + ".7"
    col_u_rms = _METER_BASE + ".8"
    col_i_rms = _METER_BASE + ".9"

    rows = _snmp_walk(ctx, community, host, col_meter_id)
    if len(rows) == 0:
        return []

    section = []
    for full_oid, meter_id in rows:
        index = full_oid[len(col_meter_id) + 1:]
        u_rms = _snmp_get_value(ctx, community, host, col_u_rms + "." + index)
        if u_rms == None or u_rms == "0":
            continue
        i_rms = _snmp_get_value(ctx, community, host, col_i_rms + "." + index)
        power_p = _snmp_get_value(ctx, community, host, col_power_p + "." + index)
        power_s = _snmp_get_value(ctx, community, host, col_power_s + "." + index)
        if i_rms == None or power_p == None or power_s == None:
            continue
        elphase = {
            "voltage": {"value": float(u_rms) / 1000.0},
            "current": {"value": float(i_rms) / 1000.0},
            "power": {"value": float(power_p)},
            "appower": {"value": float(power_s)},
        }
        section.append({"item": meter_id, "elphase": elphase})
    return section


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Discovery mode.
    if params.get("_discover"):
        if not _is_bluenet(ctx, community, host):
            return {"changed": False, "msg": "no BlueNet device at %s" % host,
                    "data": {"discovery": []}}
        section = _build_section(ctx, community, host)
        discovery = []
        for entry in section:
            discovery.append({
                "item": entry["item"],
                "params": {},
                "metrics": ["voltage", "current", "power", "appower"],
            })
        return {"changed": False,
                "msg": "discovered %d powermeters" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode — evaluate one item.
    item = params.get("item", "")
    if not _is_bluenet(ctx, community, host):
        return {"changed": False, "msg": "no BlueNet device found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = _build_section(ctx, community, host)
    found = None
    for entry in section:
        if entry["item"] == item:
            found = entry
            break

    if found == None:
        return {"changed": False,
                "msg": "Powermeter %s: not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    summary, results = _check_elphase(ctx, params, found["elphase"])

    state = "OK"
    for r in results:
        st = r.get("state")
        if st == "CRIT":
            state = "CRIT"
            break
        elif st == "WARN" and state == "OK":
            state = "WARN"

    metrics = {}
    for r in results:
        m = r.get("metric")
        v = r.get("value")
        if m != None and v != None:
            metrics[m] = v

    if len(summary) > 0:
        msg = "Powermeter %s: %s" % (item, ", ".join(summary))
    else:
        msg = "Powermeter %s" % item

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}