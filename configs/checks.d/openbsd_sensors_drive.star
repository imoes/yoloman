# openbsd_sensors_drive — Checkmk SNMP check plugin translation
# Monitors OpenBSD sensor drive status via the bsdHostSensor enterprise MIB
# (.1.3.6.1.4.1.30155.2.1.x). Only drive-type sensors (sensortype "13") are
# discovered and checked here.

_OPENBSD_MAP_STATE = {"0": "UNKNOWN", "1": "OK", "2": "WARN", "3": "CRIT"}
_OPENBSD_MAP_TYPE = {
    "0": "temp", "1": "fan", "2": "voltage",
    "9": "indicator", "13": "drive", "21": "powersupply",
}

# bsdHostSensor sensorTable column OIDs.
_SENSOR_TABLE_BASE = ".1.3.6.1.4.1.30155.2.1.2.1"
_DESCR_COL = "2"
_TYPE_COL = "3"
_VALUE_COL = "5"
_UNIT_COL = "6"
_STATE_COL = "7"


def _is_number(s):
    if s == None:
        return False
    stripped = s
    if stripped.startswith("+") or stripped.startswith("-"):
        stripped = stripped[1:]
    if stripped.count(".") > 1:
        return False
    if stripped == "":
        return False
    for c in stripped:
        if not (c >= "0" and c <= "9") and c != ".":
            return False
    return True


def _to_number(s):
    stripped = s
    if stripped.startswith("+") or stripped.startswith("-"):
        stripped = stripped[1:]
    if stripped.find(".") != -1:
        return float(s)
    return int(s)


def _walk_snmp_column(ctx, params, column_oid):
    """Walk a single SNMP column using snmpwalk -Oqn, returning {index: value}.

    Each output line is "<oid> <value>"; the index is the suffix after
    column_oid. Numeric values are converted; everything else stays a string.
    """
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid],
        mutates=False,
    )
    if res.rc != 0 and res.rc != 2:
        return {}
    out = {}
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        base_len = len(column_oid)
        if oid.startswith(column_oid + "."):
            idx = oid[base_len + 1:]
        elif oid == column_oid:
            idx = ""
        else:
            continue
        converted = val
        if type(val) == "string" and _is_number(val):
            converted = _to_number(val)
        out[idx] = converted
    return out


def _parse_sensors(ctx, params):
    """Reproduce parse_openbsd_sensors using SNMP. Returns {item: SensorEntry}
    or None if the device is absent (not OpenBSD with bsdHostSensor)."""
    # detect=exists(".1.3.6.1.4.1.30155.2.1.1.0")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    probe = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         ".1.3.6.1.4.1.30155.2.1.1.0"],
        mutates=False,
    )
    if probe.rc != 0:
        return None

    descr = _walk_snmp_column(ctx, params, _SENSOR_TABLE_BASE + "." + _DESCR_COL)
    stype = _walk_snmp_column(ctx, params, _SENSOR_TABLE_BASE + "." + _TYPE_COL)
    value = _walk_snmp_column(ctx, params, _SENSOR_TABLE_BASE + "." + _VALUE_COL)
    unit = _walk_snmp_column(ctx, params, _SENSOR_TABLE_BASE + "." + _UNIT_COL)
    state = _walk_snmp_column(ctx, params, _SENSOR_TABLE_BASE + "." + _STATE_COL)

    indices = []
    seen = {}
    for col in (descr, stype, value, unit, state):
        for k in col.keys():
            if k not in seen:
                seen[k] = True
                indices.append(k)

    parsed = {}
    used = {}
    for idx in indices:
        t = stype.get(idx, "0")
        if t not in _OPENBSD_MAP_TYPE:
            continue
        v = value.get(idx, "")
        if t == "0" and v == "-273.15":
            continue
        if t in ("1", "2"):
            vf = 0
            if type(v) == "float" or type(v) == "int":
                vf = v
            elif type(v) == "string" and _is_number(v):
                vf = _to_number(v)
            if vf == 0:
                continue

        s = state.get(idx, "0")
        mapped_state = _OPENBSD_MAP_STATE.get(s, "UNKNOWN")
        entry = {
            "state": mapped_state,
            "value": v,
            "unit": unit.get(idx, ""),
            "type": _OPENBSD_MAP_TYPE[t],
        }

        name = descr.get(idx, str(idx))
        if name in used:
            used[name] = used[name] + 1
            name = name + "/" + str(used[name])
        else:
            used[name] = 0
        parsed[name] = entry
    return parsed


def main(ctx, params):
    if params.get("_discover"):
        section = _parse_sensors(ctx, params)
        if section == None:
            return {"changed": False, "msg": "openbsd_sensors_drive not applicable",
                    "data": {"discovery": [], "host_labels": {}}}
        discovery = []
        for key, values in section.items():
            if values["type"] == "drive":
                discovery.append({
                    "item": key,
                    "params": {},
                    "metrics": [],
                    "service_labels": {
                        "openbsd.sensor.unit": values["unit"],
                    },
                })
        return {"changed": False,
                "msg": "discovered %d drive sensors" % len(discovery),
                "data": {"discovery": discovery,
                         "host_labels": {"cmk/os_family": "openbsd"}}}

    item = params.get("item", "")
    section = _parse_sensors(ctx, params)
    if section == None:
        return {"changed": False, "msg": "openbsd_sensors_drive not applicable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = section.get(item)
    if data == None:
        return {"changed": False, "msg": "no drive sensor item '%s'" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = data["state"]
    summary = "Status: %s" % str(data["value"])
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": summary}}