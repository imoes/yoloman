# Translated from Checkmk janitza_umg (SNMP) check plugin.
# Monitors Janitza UMG power meters (UMG96, UMG604, UMG508) over SNMP.

# --- Constants ---------------------------------------------------------------

_DEVICE_TYPES = {
    ".1.3.6.1.4.1.34278.8.6": "96",
    ".1.3.6.1.4.1.34278.10.1": "604",
    ".1.3.6.1.4.1.34278.10.4": "508",
}

_INFO_OFFSETS = {
    "508": {"energy": 4, "sumenergy": 5, "misc": 8},
    "604": {"energy": 4, "sumenergy": 5, "misc": 8},
    "96": {"energy": 3, "sumenergy": 4, "misc": 6},
}

_JANITZA_BASE = ".1.3.6.1.4.1.34278"
_JANITZA_OID_SUFFIXES = ["1", "2", "3", "4", "5", "6", "7", "8"]
_SYSOID_OID = ".1.3.6.1.2.1.1.2.0"

_TEMP_SENTINEL = -100.0


# --- SNMP helpers ------------------------------------------------------------

def _snmp_get(ctx, oid):
    community = ctx.params.get("community", "public")
    host = ctx.params.get("host", "localhost")
    return ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )


def _snmp_walk(ctx, oid):
    community = ctx.params.get("community", "public")
    host = ctx.params.get("host", "localhost")
    return ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )


def _parse_walk_lines(stdout):
    result = {}
    if not stdout:
        return result
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid_part, value_part = parts
        result[oid_part] = value_part
    return result


def _strip_quotes(s):
    if s == None:
        return ""
    s = s.strip()
    if s.startswith('"') and s.endswith('"'):
        s = s[1:-1]
    return s


def _to_float(s):
    s = _strip_quotes(s)
    if s == "":
        return 0.0
    neg = False
    digits = s
    if s.startswith("-"):
        neg = True
        digits = s[1:]
    elif s.startswith("+"):
        digits = s[1:]
    if digits.replace(".", "", 1).isdigit():
        return float(s)
    return 0.0


def _to_int(s):
    s = _strip_quotes(s)
    if s == "":
        return 0
    neg = False
    digits = s
    if s.startswith("-"):
        neg = True
        digits = s[1:]
    elif s.startswith("+"):
        digits = s[1:]
    if digits.isdigit():
        return int(s)
    return 0


# --- Core parsing ------------------------------------------------------------

def _build_section(ctx):
    """Fetch all Janitza UMG OIDs via SNMP and parse into a Section dict.
    Returns None if the device is not a Janitza UMG or is unreachable."""
    sysoid_res = _snmp_get(ctx, _SYSOID_OID)
    if sysoid_res.rc != 0:
        return None
    sysoid = _strip_quotes(sysoid_res.stdout)

    dev_type = _DEVICE_TYPES.get(sysoid)
    if dev_type == None:
        return None

    offsets = _INFO_OFFSETS[dev_type]

    raw = {}
    raw[1] = {"0": sysoid}

    all_ok = True
    for col_idx, oid_suffix in enumerate(_JANITZA_OID_SUFFIXES, start=2):
        walk_res = _snmp_walk(ctx, _JANITZA_BASE + "." + oid_suffix)
        if walk_res.rc != 0:
            all_ok = False
            break
        parsed = _parse_walk_lines(walk_res.stdout)
        col_base = _JANITZA_BASE + "." + oid_suffix + "."
        indexed = {}
        for full_oid, value in parsed.items():
            if full_oid.startswith(col_base):
                idx = full_oid[len(col_base):]
                indexed[idx] = value
        raw[col_idx] = indexed

    if not all_ok:
        return None

    def flatten(col):
        rows = raw.get(col, {})
        if not rows:
            return []
        indices = sorted(rows.keys(), key=lambda x: int(x))
        return [rows[i] for i in indices]

    string_tables = []
    string_tables.append([[sysoid]])
    for col_idx in range(2, 10):
        vals = flatten(col_idx)
        string_tables.append([[v] for v in vals])

    return _parse_janitza_umg(string_tables, dev_type, offsets)


def _parse_janitza_umg(string_tables, dev_type, offsets):
    """Reproduce parse_janitza_umg_inphase on the fetched data."""
    if not string_tables[0] or not string_tables[0][0]:
        return None

    def flatten(line):
        return [x[0] for x in line]

    rmsphase = flatten(string_tables[1])
    sumphase = flatten(string_tables[2])
    energy = flatten(string_tables[offsets["energy"]])
    sumenergy = flatten(string_tables[offsets["sumenergy"]])

    if dev_type in ["508", "604"]:
        num_phases = 4
        num_currents = 4
    else:
        num_phases = 3
        num_currents = 6

    counts = [
        num_phases,
        3,
        num_currents,
        num_phases,
        num_phases,
        num_phases,
        num_phases,
    ]

    def _offset(block_id, phase):
        total = 0
        for i in range(block_id):
            total += counts[i]
        return total + phase

    phases = {}
    for phase in range(num_phases):
        ph_name = "Phase %d" % (phase + 1)
        phases[ph_name] = {
            "voltage": _to_float(rmsphase[_offset(0, phase)]) / 10.0,
            "current": _to_float(rmsphase[_offset(2, phase)]) / 1000.0,
            "power": _to_int(rmsphase[_offset(3, phase)]),
            "appower": _to_int(rmsphase[_offset(5, phase)]),
            "energy": _to_float(energy[phase]) / 10.0,
        }

    total = {
        "power": _to_int(sumphase[0]),
        "energy": _to_int(sumenergy[0]),
    }

    raw_misc = flatten(string_tables[offsets["misc"]])
    if not raw_misc:
        raw_frequency = "0"
        raw_temperatures = []
    else:
        raw_frequency = raw_misc[0]
        raw_temperatures = raw_misc[1:]

    temperature = {}
    for num, v in enumerate(raw_temperatures, start=1):
        tv = _to_float(v) / 10.0
        temperature[str(num)] = tv

    return {
        "phases": phases,
        "total": total,
        "frequency": _to_float(raw_frequency) / 100.0,
        "temperature": temperature,
    }


# --- Threshold helpers -------------------------------------------------------

def _level(value, levels):
    if levels == None:
        return "OK"
    warn = levels[0]
    crit = levels[1]
    if crit != None and value >= crit:
        return "CRIT"
    if warn != None and value >= warn:
        return "WARN"
    return "OK"


def _level_lower(value, levels):
    if levels == None:
        return "OK"
    warn = levels[0]
    crit = levels[1]
    if crit != None and value <= crit:
        return "CRIT"
    if warn != None and value <= warn:
        return "WARN"
    return "OK"


def _worst(a, b):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    oa = order.get(a, 3)
    ob = order.get(b, 3)
    if oa >= ob:
        return a
    return b


def _level_suffix(state, levels):
    if levels == None or state == "OK":
        return ""
    if state == "WARN":
        return "(warn)"
    if state == "CRIT":
        return "(crit)"
    return ""


def _check_elphase(params, phase):
    metrics = {}
    details = []
    state = "OK"

    v_thresh = params.get("voltage")
    v_state = _level_lower(phase["voltage"], v_thresh)
    state = _worst(state, v_state)
    metrics["voltage"] = phase["voltage"]
    details.append("Voltage: %f V %s" % (phase["voltage"],
        _level_suffix(v_state, v_thresh)))

    i_thresh = params.get("current")
    i_state = _level_lower(phase["current"], i_thresh)
    state = _worst(state, i_state)
    metrics["current"] = phase["current"]
    details.append("Current: %f A %s" % (phase["current"],
        _level_suffix(i_state, i_thresh)))

    p_thresh = params.get("power")
    p_state = _level(phase["power"], p_thresh)
    state = _worst(state, p_state)
    metrics["power"] = phase["power"]
    details.append("Power: %d W %s" % (phase["power"],
        _level_suffix(p_state, p_thresh)))

    ap_thresh = params.get("appower")
    ap_state = _level(phase["appower"], ap_thresh)
    state = _worst(state, ap_state)
    metrics["appower"] = phase["appower"]
    details.append("Apparent power: %d VA %s" % (phase["appower"],
        _level_suffix(ap_state, ap_thresh)))

    e_thresh = params.get("energy")
    e_state = _level(phase["energy"], e_thresh)
    state = _worst(state, e_state)
    metrics["energy"] = phase["energy"]
    details.append("Energy: %f Wh %s" % (phase["energy"],
        _level_suffix(e_state, e_thresh)))

    if phase["appower"] > 0:
        cosphi = phase["power"] / phase["appower"]
    else:
        cosphi = 0.0
    cf_thresh = params.get("cosphi")
    cf_state = _level(cosphi, cf_thresh)
    state = _worst(state, cf_state)
    metrics["cosphi"] = cosphi
    details.append("Cos(Phi): %f %s" % (cosphi,
        _level_suffix(cf_state, cf_thresh)))

    return state, metrics, details


def _check_frequency(params, frequency):
    levels_lower = params.get("levels_lower", (0, 0))
    warn = levels_lower[0]
    crit = levels_lower[1]
    state = "OK"
    if crit != None and frequency <= crit:
        state = "CRIT"
    elif warn != None and frequency <= warn:
        state = "WARN"
    metrics = {"in_freq": frequency}
    details = "Frequency: %f Hz" % frequency
    if state != "OK":
        details = details + " %s" % state.lower()
    return state, metrics, details


def _check_temperature(params, reading):
    levels = params.get("levels")
    state = "OK"
    if levels != None:
        warn = levels[0]
        crit = levels[1]
        if crit != None and reading >= crit:
            state = "CRIT"
        elif warn != None and reading >= warn:
            state = "WARN"
    metrics = {"temperature": reading}
    details = "Temperature: %f C" % reading
    if state != "OK":
        details = details + " %s" % state.lower()
    return state, metrics, details


# --- Discovery ---------------------------------------------------------------

def _discovery(ctx, params):
    section = _build_section(ctx)
    if section == None:
        test = _snmp_get(ctx, _SYSOID_OID)
        if test.rc == 127:
            return {"changed": False,
                    "msg": "snmpget not available; janitza checks not applicable",
                    "data": {"discovery": [], "host_labels": {}}}
        if test.rc != 0:
            return {"changed": False,
                    "msg": "no janitza device reachable at %s" % params.get("host", "localhost"),
                    "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False,
                "msg": "host is not a Janitza UMG meter",
                "data": {"discovery": [], "host_labels": {}}}

    discovery = []
    for phase_name in section["phases"]:
        discovery.append({
            "item": phase_name,
            "params": {"voltage": None, "current": None, "power": None,
                       "appower": None, "energy": None, "cosphi": None},
            "metrics": ["voltage", "current", "power", "appower", "energy", "cosphi"],
        })
    discovery.append({
        "item": "1",
        "params": {"levels_lower": (0, 0)},
        "metrics": ["in_freq"],
    })
    for num, temp in section["temperature"].items():
        if temp != _TEMP_SENTINEL:
            discovery.append({
                "item": num,
                "params": {},
                "metrics": ["temperature"],
            })

    host_labels = {"cmk/snmp": "janitza", "cmk/device_type": "umg"}
    return {"changed": False,
            "msg": "discovered %d janitza services" % len(discovery),
            "data": {"discovery": discovery, "host_labels": host_labels}}


# --- Check -------------------------------------------------------------------

def _check(ctx, params):
    item = params.get("item", "")
    section = _build_section(ctx)
    if section == None:
        test = _snmp_get(ctx, _SYSOID_OID)
        if test.rc == 127:
            return {"changed": False,
                    "msg": "snmpget not available — janitza check not applicable",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        if test.rc != 0:
            return {"changed": False,
                    "msg": "janitza device not reachable at %s" % params.get("host", "localhost"),
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        return {"changed": False,
                "msg": "host is not a Janitza UMG meter",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if item.startswith("Phase"):
        phase = section["phases"].get(item)
        if phase == None:
            return {"changed": False,
                    "msg": "no such phase: " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        state, metrics, details = _check_elphase(params, phase)
        return {"changed": False,
                "msg": "%s: %s" % (item, "; ".join(details)),
                "data": {"state": state, "metrics": metrics, "details": "\n".join(details)}}

    if item == "1":
        state, metrics, details = _check_frequency(params, section["frequency"])
        return {"changed": False,
                "msg": details,
                "data": {"state": state, "metrics": metrics, "details": details}}

    temp = section["temperature"].get(item)
    if temp == None:
        return {"changed": False,
                "msg": "no such temperature sensor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if temp == _TEMP_SENTINEL:
        return {"changed": False,
                "msg": "temperature sensor %s not present (sentinel)" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    state, metrics, details = _check_temperature(params, temp)
    return {"changed": False,
            "msg": details,
            "data": {"state": state, "metrics": metrics, "details": details}}


# --- Main entry point --------------------------------------------------------

def main(ctx, params):
    ctx.params = params
    if params.get("_discover"):
        return _discovery(ctx, params)
    return _check(ctx, params)