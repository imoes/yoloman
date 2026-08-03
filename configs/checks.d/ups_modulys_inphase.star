# Checkmk check: ups_modulys_inphase -> Input %s
# Translated to read-only Starlark for the yolo-man agent.

# Metric names exposed by this check (elphase values).
_METRICS = ["frequency", "voltage", "current"]

# Threshold defaults from check_default_parameters / el_inphase ruleset.
# Real Checkmk rules: upper levels warn/crit on frequency, voltage, current.
# Provide reasonable defaults mirroring Checkmk elphase library behaviour.
_WARN_DEFAULT = 0
_CRIT_DEFAULT = 0

def _state_for_value(value, warn, crit, upper):
    # value: number or None ; warn/crit: (warn, crit) tuple
    if value == None:
        return "UNKNOWN", 0
    w, c = warn, crit
    if upper:
        if value >= c:
            return "CRIT", value
        if value >= w:
            return "WARN", value
    else:
        if value <= c:
            return "CRIT", value
        if value <= w:
            return "WARN", value
    return "OK", value

def _grade_elphase(phase):
    # phase: dict with frequency, voltage, current (each a number or None)
    worst = "OK"
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    metrics = {}
    messages = []
    for k in _METRICS:
        v = phase.get(k)
        if v == None:
            continue
        metrics[k] = v
    # Use default thresholds (0/0 means disabled -> OK) since elphase defaults
    # have no active thresholds unless configured. Mirror Checkmk: levels absent
    # => OK for present values.
    return worst, metrics, messages

def _parse_value(raw):
    if raw == None or raw == "":
        return None
    if raw.isdigit():
        return int(raw) / 10.0
    return None

def _parse_phase(raw_frequency, raw_voltage, raw_current):
    return {
        "frequency": _parse_value(raw_frequency),
        "voltage": _parse_value(raw_voltage),
        "current": _parse_value(raw_current),
    }

def _parse_inphase_table(stdout):
    # snmpget -Oqv for a full subtree is impractical; we use snmpwalk -Oqn
    # on the column OID range. But the SNMPTree fetch reads a single row
    # of 10 OIDs under base.1..10. We replicate with a single snmpget
    # per OID is expensive; instead use snmpwalk -Oqn on base.1.1.0 path.
    # Actually SNMPTree(base, [1..10]) fetches scalar oids:
    #   base.1, base.2, ..., base.10  (each ending .0)
    # We issue individual snmpget -Oqv calls for each of the 10 OIDs.
    return stdout

def _snmp_get(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc == 0:
        return res.stdout.strip()
    # rc 127 = no such name / not present ; 2 = timeout/err
    return ""

def _fetch_inphase(ctx, host, community):
    base = ".1.3.6.1.4.1.2254.2.4.4"
    oids = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10"]
    vals = []
    for i in oids:
        v = _snmp_get(ctx, host, community, base + "." + i + ".0")
        vals.append(v)
    return vals

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        # First confirm this host is a Modulys UPS via the detection OID.
        sys_oid = _snmp_get(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
        if sys_oid == "":
            # Product not present -> empty discovery.
            return {"changed": False, "msg": "no data", "data": {"discovery": []}}
        if sys_oid != ".1.3.6.1.4.1.2254.2.4":
            return {"changed": False, "msg": "not a Modulys UPS", "data": {"discovery": []}}

        # Fetch the in-phase input table row.
        vals = _fetch_inphase(ctx, host, community)
        first_line = vals
        parsed = {}
        if len(first_line) >= 10:
            phase_1 = _parse_phase(first_line[1], first_line[2], first_line[3])
            if phase_1.get("frequency") != None or phase_1.get("voltage") != None or phase_1.get("current") != None:
                parsed["Phase 1"] = phase_1
            # First column (index 0) indicates number of phases ("3" => 3-phase).
            if first_line[0] == "3":
                phase_2 = _parse_phase(first_line[4], first_line[5], first_line[6])
                if phase_2.get("frequency") != None or phase_2.get("voltage") != None or phase_2.get("current") != None:
                    parsed["Phase 2"] = phase_2
                phase_3 = _parse_phase(first_line[7], first_line[8], first_line[9])
                if phase_3.get("frequency") != None or phase_3.get("voltage") != None or phase_3.get("current") != None:
                    parsed["Phase 3"] = phase_3

        out = []
        for item in sorted(parsed.keys()):
            out.append({"item": item, "params": {}, "metrics": _METRICS})
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}

    # CHECK MODE
    item = params.get("item", "")
    # Re-fetch to grade the requested item.
    sys_oid = _snmp_get(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
    if sys_oid == "" or sys_oid != ".1.3.6.1.4.1.2254.2.4":
        return {"changed": False, "msg": "Modulys UPS not present", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    vals = _fetch_inphase(ctx, host, community)
    first_line = vals
    parsed = {}
    if len(first_line) >= 10:
        phase_1 = _parse_phase(first_line[1], first_line[2], first_line[3])
        if phase_1.get("frequency") != None or phase_1.get("voltage") != None or phase_1.get("current") != None:
            parsed["Phase 1"] = phase_1
        if first_line[0] == "3":
            phase_2 = _parse_phase(first_line[4], first_line[5], first_line[6])
            if phase_2.get("frequency") != None or phase_2.get("voltage") != None or phase_2.get("current") != None:
                parsed["Phase 2"] = phase_2
            phase_3 = _parse_phase(first_line[7], first_line[8], first_line[9])
            if phase_3.get("frequency") != None or phase_3.get("voltage") != None or phase_3.get("current") != None:
                parsed["Phase 3"] = phase_3

    phase = parsed.get(item)
    if phase == None:
        return {"changed": False, "msg": "no such phase: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Apply elphase threshold logic. Default el_inphase ruleset has no
    # mandatory thresholds; warn/crit arrive via params for each value.
    # We grade each present value against its configured levels.
    worst = "OK"
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    metrics = {}
    details_lines = []
    for k in _METRICS:
        v = phase.get(k)
        if v == None:
            continue
        metrics[k] = v
        levels = params.get(k + "_levels")
        if levels != None and len(levels) >= 2:
            w = levels[0]
            c = levels[1]
            st = _state_for_value(v, w, c, True)
            if order[st] > order[worst]:
                worst = st
        details_lines.append("%s: %f" % (k, v))

    msg = ", ".join(details_lines) if details_lines else "no readings"
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": worst,
            "metrics": metrics,
            "details": msg,
        },
    }