def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe for the HP ProCurve device (sysObjectID enterprise .11.2.3.7.x)
    sysid = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv",
                     host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if sysid.rc != 0 or (sysid.rc == 127):
        if params.get("_discover"):
            return {"changed": False, "msg": "no HP ProCurve device found",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "no HP ProCurve device found at " + host,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sysid_val = sysid.stdout
    if not _is_procurve(sysid_val):
        if params.get("_discover"):
            return {"changed": False, "msg": "not an HP ProCurve device",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "host is not an HP ProCurve device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch the sensor table columns 1 (name), 2 (type), 4 (value), 7 (model)
    base = ".1.3.6.1.4.1.11.2.14.11.1.2.6.1"
    col1 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
                    base + ".1"], mutates=False)
    col2 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
                    base + ".2"], mutates=False)
    col4 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
                    base + ".4"], mutates=False)
    col7 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
                    base + ".7"], mutates=False)

    sensors = _build_sensors(col1.stdout, col2.stdout, col4.stdout, col7.stdout)

    if params.get("_discover"):
        out = []
        for s in sensors:
            if s["status"] != "5":
                out.append({"item": s["name"], "params": {}, "metrics": []})
        return {"changed": False,
                "msg": "discovered %d sensors" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    for s in sensors:
        if s["name"] == item:
            state, readable = _STATUS_MAP[s["status"]]
            stype = _sensor_type(s["type"])
            msg = 'Condition of %s "%s" is %s' % (stype, s["model"], readable)
            return {"changed": False, "msg": msg,
                    "data": {"state": state, "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "item not found in snmp data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}


_STATUS_MAP = {
    "1": ("UNKNOWN", "unknown"),
    "2": ("CRIT", "bad"),
    "3": ("WARN", "warning"),
    "4": ("OK", "good"),
    "5": ("WARN", "notPresent"),
}

_SENSOR_TYPE_SUFFIX_MAP = {
    "11.2.3.7.8.3.1": "PSU",
    "11.2.3.7.8.3.2": "FAN",
    "11.2.3.7.8.3.3": "Temp",
    "11.2.3.7.8.3.4": "FutureSlot",
}


def _is_procurve(sysid_val):
    return sysid_val.find(".11.2.3.7.11") != -1 or sysid_val.find(".11.2.3.7.8") != -1


def _sensor_type(type_input):
    for suffix, name in _SENSOR_TYPE_SUFFIX_MAP.items():
        if type_input.endswith(suffix):
            return name
    return ""


def _build_sensors(col1, col2, col4, col7):
    def _parse_col(text):
        rows = {}
        if not text:
            return rows
        for line in text.split("\n"):
            if not line:
                continue
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid, val = parts
            idx = oid[len(".1.3.6.1.4.1.11.2.14.11.1.2.6.1.1")] if False else None
            # Extract index: everything after ".1" / ".2" / ".4" / ".7"
            rows[oid] = val.strip()
        return rows
    # Re-parse properly using column base lengths
    by_index = {}

    def _load(text, base_col, field):
        if not text:
            return
        col_oid = ".1.3.6.1.4.1.11.2.14.11.1.2.6.1." + base_col
        for line in text.split("\n"):
            if not line:
                continue
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            val = parts[1].strip()
            if not oid.startswith(col_oid + "."):
                continue
            idx = oid[len(col_oid) + 1:]
            if idx not in by_index:
                by_index[idx] = {}
            by_index[idx][field] = val

    _load(col1, "1", "name")
    _load(col2, "2", "type")
    _load(col4, "4", "status")
    _load(col7, "7", "model")

    out = []
    for idx in sorted(by_index.keys()):
        rec = by_index[idx]
        out.append({
            "name": rec.get("name", ""),
            "type": rec.get("type", ""),
            "status": rec.get("status", "1"),
            "model": rec.get("model", ""),
        })
    return out