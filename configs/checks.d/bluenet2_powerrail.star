# bluenet2_powerrail — read-only Starlark check module (SNMP to Bachmann BlueNet2 PDU)

# ---- OID bases ----
OID_BASE_VAR    = ".1.3.6.1.4.1.31770.2.2.8"
OID_COL_TYPE    = OID_BASE_VAR + ".2.1.6"
OID_COL_STATUS  = OID_BASE_VAR + ".2.1.7"
OID_COL_SCALING = OID_BASE_VAR + ".2.1.9"
OID_COL_DATA    = OID_BASE_VAR + ".4.1.5"
OID_SYSOID      = ".1.3.6.1.2.1.1.2.0"

OID_BASE_CIRCUIT = ".1.3.6.1.4.1.31770.2.2.6.2.1"
OID_BASE_PHASE   = ".1.3.6.1.4.1.31770.2.2.6.3.1"
OID_BASE_RCM     = ".1.3.6.1.4.1.31770.2.2.6.6.1"
OID_BASE_SOCKET  = ".1.3.6.1.4.1.31770.2.2.6.5.1"
OID_BASE_FUSE    = ".1.3.6.1.4.1.31770.2.2.6.4.1"

# status: code -> (state_number, readable)
STATUS_MAP = {
    "0": (0, "expected"),
    "1": (3, "undefined"),
    "2": (0, "OK"),
    "3": (2, "error high"),
    "4": (2, "error low"),
    "5": (1, "warning high"),
    "6": (1, "warning low"),
    "7": (2, "lost"),
    "8": (1, "deactivate"),
    "11": (2, "on alarm"),
    "12": (2, "off alarm"),
    "20": (1, "off"),
    "39": (2, "high"),
    "40": (1, "low"),
    "41": (2, "alarm"),
    "42": (1, "warning"),
    "43": (0, "ok"),
}

# phase-type OID suffix -> (parsedkey, label, metric)
PHASE_TYPES = {
    "1": ("phases", "Phase", "voltage"),
    "4": ("phases", "Phase", "current"),
    "18": ("phases", "Phase", "appower"),
    "19": ("phases", "Phase", "power"),
    "23": ("phases", "Phase", "frequency"),
    "7": ("rcm_phases", "RCM Phase", "differential_current_ac"),
    "8": ("rcm_phases", "RCM Phase", "differential_current_dc"),
    "9": ("inlet", "Neutral Current", "current"),
}

SENSOR_TYPES = {
    "256": "temp",
    "257": "humidity",
}


def _strip_value(raw):
    s = raw.strip()
    if ": " in s:
        s = s[s.find(": ") + 2:]
    s = s.strip()
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        s = s[1:-1]
    return s


def _oid_index_parts(oid):
    parts = []
    for p in oid.split("."):
        if p != "":
            parts.append(p)
    return parts


def _snmp_get(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return ""
    return _strip_value(res.stdout)


def _snmp_walk(ctx, host, community, col_oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_oid],
        mutates=False,
    )
    if res.rc != 0:
        return []
    rows = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if line == "" or " " not in line:
            continue
        sp = line.find(" ")
        full = line[:sp]
        val = _strip_value(line[sp + 1:])
        rows.append((full, val))
    return rows


def _pdu_name(pdu_info):
    if pdu_info == "0":
        return "Master"
    return "PDU %s" % pdu_info


# ---- integer power: Starlark has no ** nor pow() ----
def _pow_int(base, exp):
    if exp < 0:
        return 0
    result = 1
    b = int(base)
    for _ in range(exp):
        result = result * b
    return result


def _pow_float(base, exp):
    if exp < 0:
        return 1.0 / _pow_float(base, -exp)
    result = 1.0
    b = float(base)
    for _ in range(int(exp)):
        result = result * b
    return result


def _to_float(s):
    if s == "" or s == None:
        return 0.0
    neg = False
    t = s
    if s.startswith("-"):
        neg = True
        t = s[1:]
    if "." in t:
        ip, fp = t.split(".", 1)
        ip = ip if ip != "" else "0"
        fp = fp if fp != "" else "0"
        val = float(ip) + float(fp) / _pow_float(10.0, len(fp))
    else:
        if not t.isdigit():
            return 0.0
        val = float(int(t))
    if neg:
        val = -val
    return val


def _gather_section(ctx, host, community):
    # Detect BlueNet2 device
    sysoid_val = _snmp_get(ctx, host, community, OID_SYSOID)
    if sysoid_val != "" and ".1.3.6.1.4.1.31770.2.1" not in sysoid_val:
        return None
    if sysoid_val == "" and host == "localhost":
        return None

    # Inlet/circuits (OIDEnd = first component pair)
    circuit_rows = _snmp_walk(ctx, host, community, OID_BASE_CIRCUIT)
    inlet_map = {}
    for full, val in circuit_rows:
        parts = _oid_index_parts(full)
        oidend = ".".join(parts[:2])
        if oidend not in inlet_map:
            inlet_map[oidend] = {"name": oidend, "friendly": oidend}

    # Phase name/friendly columns
    def _colmap(base, suffix):
        result = {}
        rows = _snmp_walk(ctx, host, community, base + "." + suffix)
        for full, val in rows:
            idx = full[len(base) + 1:]
            result[idx] = val
        return result

    phase_names = _colmap(OID_BASE_PHASE, "5")
    phase_friendly = _colmap(OID_BASE_PHASE, "6")
    phase_guid = _colmap(OID_BASE_PHASE, "4")

    rcm_names = _colmap(OID_BASE_RCM, "8")
    rcm_friendly = _colmap(OID_BASE_RCM, "9")
    rcm_guid = _colmap(OID_BASE_RCM, "7")

    sock_names = _colmap(OID_BASE_SOCKET, "7")
    sock_friendly = _colmap(OID_BASE_SOCKET, "8")
    sock_guid = _colmap(OID_BASE_SOCKET, "6")

    fuse_names = _colmap(OID_BASE_FUSE, "6")
    fuse_friendly = _colmap(OID_BASE_FUSE, "7")
    fuse_guid = _colmap(OID_BASE_FUSE, "5")

    # Variable columns
    type_rows = _snmp_walk(ctx, host, community, OID_COL_TYPE)
    status_rows = _snmp_walk(ctx, host, community, OID_COL_STATUS)
    scaling_rows = _snmp_walk(ctx, host, community, OID_COL_SCALING)
    data_rows = _snmp_walk(ctx, host, community, OID_COL_DATA)

    type_by_oid = {}
    for full, val in type_rows:
        idx = full[len(OID_COL_TYPE) + 1:]
        type_by_oid[idx] = val
    status_by_oid = {}
    for full, val in status_rows:
        idx = full[len(OID_COL_STATUS) + 1:]
        status_by_oid[idx] = val
    scaling_by_oid = {}
    for full, val in scaling_rows:
        idx = full[len(OID_COL_SCALING) + 1:]
        scaling_by_oid[idx] = val
    data_by_oid = {}
    for full, val in data_rows:
        idx = full[len(OID_COL_DATA) + 1:]
        data_by_oid[idx] = val

    parsed = {
        "inlet": {},
        "phases": {},
        "rcm_phases": {},
        "sockets": {},
        "fuses": {},
        "sensors": {"temp": {}, "humidity": {}},
    }

    all_var_oids = sorted(type_by_oid.keys())
    for var_oid in all_var_oids:
        ty = type_by_oid[var_oid]
        if ty not in PHASE_TYPES and ty not in SENSOR_TYPES:
            continue
        status = status_by_oid.get(var_oid, "2")
        scaling = scaling_by_oid.get(var_oid, "0")
        data = data_by_oid.get(var_oid, "0")

        status_info = STATUS_MAP.get(status, (2, "unknown"))

        # Compute reading = data * 10^scaling
        data_val = _to_float(data)
        scaling_val = int(scaling) if scaling.lstrip("-").isdigit() else 0
        reading_f = data_val * _pow_float(10.0, scaling_val)

        oid_parts = var_oid.split(".")
        if len(oid_parts) >= 2:
            inlet_id_str = ".".join(oid_parts[0:2])
            inlet_name = inlet_map.get(inlet_id_str, {}).get("name", inlet_id_str)
        else:
            inlet_name = var_oid

        if ty in PHASE_TYPES:
            phase_ty, phase_txt, metric = PHASE_TYPES[ty]
            phase_idx = oid_parts[3] if len(oid_parts) > 3 else "0"
            idx_num = int(phase_idx) if phase_idx.isdigit() else 0
            if phase_ty == "phases":
                key = "%s %s %d" % (inlet_name, phase_txt, idx_num + 1)
                entry = parsed["phases"].setdefault(key, {})
                entry[metric] = (reading_f, status_info)
            elif phase_ty == "rcm_phases":
                key = "%s %s %d" % (inlet_name, phase_txt, idx_num + 1)
                entry = parsed["rcm_phases"].setdefault(key, {})
                entry[metric] = (reading_f, status_info)
            elif phase_ty == "inlet":
                key = "%s %s" % (inlet_name, phase_txt)
                entry = parsed["inlet"].setdefault(key, {})
                entry[metric] = (reading_f, status_info)
        elif ty in SENSOR_TYPES:
            kind = SENSOR_TYPES[ty]
            pdu_num = oid_parts[0] if len(oid_parts) > 0 else "0"
            ch_internal = oid_parts[3] if len(oid_parts) > 3 else "0"
            ch_external = oid_parts[4] if len(oid_parts) > 4 else "0"
            sensor_name = "Sensor %s %s/%s" % (
                _pdu_name(pdu_num), ch_internal, ch_external)
            parsed["sensors"][kind][sensor_name] = (reading_f, status_info)

    return parsed


def _get_levels(params, key, default):
    lv = params.get(key, default)
    if type(lv) == "list" and len(lv) >= 2:
        return (float(lv[0]), float(lv[1]))
    if type(lv) == "tuple" and len(lv) >= 2:
        return (float(lv[0]), float(lv[1]))
    return (float(default[0]), float(default[1]))


def _grade_temp(reading, dev_state, warn, crit):
    if dev_state >= 2:
        return "CRIT"
    if dev_state == 1:
        return "WARN"
    if reading >= crit:
        return "CRIT"
    if reading >= warn:
        return "WARN"
    return "OK"


def _grade_humidity(reading, warn, crit, lw, lc):
    if reading >= crit:
        return "CRIT"
    if reading <= lc:
        return "CRIT"
    if reading >= warn:
        return "WARN"
    if reading <= lc:
        return "WARN"
    return "OK"


def _state_to_str(n):
    if n == 2:
        return "CRIT"
    if n == 1:
        return "WARN"
    if n == 0:
        return "OK"
    return "UNKNOWN"


def _fmt_num(v):
    if v == int(v):
        return str(int(v))
    return "%f" % v


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        section = _gather_section(ctx, host, community)
        if section == None:
            return {
                "changed": False,
                "msg": "no BlueNet2 PDU detected on %s" % host,
                "data": {"discovery": []},
            }
        discovery = []
        for key in section.get("phases", {}):
            discovery.append({
                "item": key,
                "params": {"levels": params.get("el_inphase_levels", [50.0, 60.0])},
                "metrics": ["voltage", "current", "appower", "power", "frequency"],
            })
        for key in section.get("rcm_phases", {}):
            discovery.append({
                "item": key,
                "params": {
                    "levels": params.get("differential_current_ac", [3.5, 30.0]),
                    "levels_dc": params.get("differential_current_dc", [70.0, 100.0]),
                },
                "metrics": ["differential_current_ac", "differential_current_dc"],
            })
        for key in section.get("sockets", {}):
            discovery.append({
                "item": key,
                "params": {"levels": params.get("ups_outphase_levels", [10.0, 12.0])},
                "metrics": ["voltage", "current", "appower", "power", "frequency"],
            })
        for key in section.get("fuses", {}):
            discovery.append({
                "item": key,
                "params": {"levels": params.get("ups_outphase_levels", [10.0, 12.0])},
                "metrics": ["voltage", "current", "appower", "power", "frequency"],
            })
        for key in section.get("inlet", {}):
            discovery.append({
                "item": key,
                "params": {"levels": params.get("el_inphase_levels", [50.0, 60.0])},
                "metrics": ["current"],
            })
        for key in section.get("sensors", {}).get("temp", {}):
            discovery.append({
                "item": key,
                "params": {"levels": params.get("temp_levels", [30.0, 35.0])},
                "metrics": ["temperature"],
            })
        for key in section.get("sensors", {}).get("humidity", {}):
            discovery.append({
                "item": key,
                "params": {
                    "levels": params.get("humidity_levels", [75.0, 80.0]),
                    "levels_lower": params.get("humidity_levels_lower", [5.0, 8.0]),
                },
                "metrics": ["humidity"],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # CHECK MODE
    item = params.get("item", "")
    section = _gather_section(ctx, host, community)
    if section == None:
        return {
            "changed": False,
            "msg": "no BlueNet2 PDU detected on %s" % host,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    check_type = params.get("check_type", "phases")
    if check_type == "phases":
        target = section.get("phases", {}).get(item)
    elif check_type == "rcm_phases":
        target = section.get("rcm_phases", {}).get(item)
    elif check_type == "sockets":
        target = section.get("sockets", {}).get(item)
    elif check_type == "fuses":
        target = section.get("fuses", {}).get(item)
    elif check_type == "inlet":
        target = section.get("inlet", {}).get(item)
    elif check_type == "temp":
        target = section.get("sensors", {}).get("temp", {}).get(item)
    elif check_type == "humidity":
        target = section.get("sensors", {}).get("humidity", {}).get(item)
    else:
        target = None

    if target == None:
        return {
            "changed": False,
            "msg": "item not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if check_type in ("phases", "rcm_phases", "sockets", "fuses", "inlet"):
        metrics = {}
        details_parts = []
        worst_state = 0
        for metric_name in sorted(target.keys()):
            reading, status_info = target[metric_name]
            state_num = status_info[0]
            if state_num > worst_state:
                worst_state = state_num
            if reading == int(reading):
                metrics[metric_name] = int(reading)
            else:
                metrics[metric_name] = reading
            details_parts.append("%s: %s (%s)" % (
                metric_name, _fmt_num(reading), status_info[1]))
        state_str = _state_to_str(worst_state)
        if worst_state == 0:
            msg = item + " " + ", ".join(details_parts)
        else:
            msg = item + " " + state_str + ": " + ", ".join(details_parts)
        return {
            "changed": False,
            "msg": msg,
            "data": {
                "state": state_str,
                "metrics": metrics,
                "details": "; ".join(details_parts),
            },
        }

    if check_type == "temp":
        reading, (state_num, state_readable) = target
        warn, crit = _get_levels(params, "temp_levels", [30.0, 35.0])
        state_str = _grade_temp(reading, state_num, warn, crit)
        if state_str == "OK":
            msg = item + " temperature %s" % _fmt_num(reading)
        else:
            msg = item + " temperature %s %s" % (_fmt_num(reading), state_str)
        return {
            "changed": False,
            "msg": msg,
            "data": {
                "state": state_str,
                "metrics": {"temperature": reading},
                "details": "%s: %sC (%s)" % (
                    item, _fmt_num(reading), state_readable),
            },
        }

    # humidity
    reading, (state_num, state_readable) = target
    warn, crit = _get_levels(params, "humidity_levels", [75.0, 80.0])
    lw, lc = _get_levels(params, "humidity_levels_lower", [5.0, 8.0])
    state_str = _grade_humidity(reading, warn, crit, lw, lc)
    if state_str == "OK":
        msg = item + " humidity %s%%" % _fmt_num(reading)
    else:
        msg = item + " humidity %s%% %s" % (_fmt_num(reading), state_str)
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state_str,
            "metrics": {"humidity": reading},
            "details": "%s: %s%% (%s)" % (
                item, _fmt_num(reading), state_readable),
        },
    }