# Supermicro hardware health check (translated from Checkmk SNMP plugin).
# Read-only: never mutates the system, always changed=False.

# OID roots used by the three sections.
_OID_SYS_OBJID = ".1.3.6.1.2.1.1.2.0"
_OID_SYS_DESC = ".1.3.6.1.2.1.1.1.0"
_OID_FAN1 = ".1.3.6.1.4.1.10876.2.1.1.1.1.2.1"

# Overall health: .1.3.6.1.4.1.10876.2, columns 2 (status) and 3 (text).
_OID_HEALTH_BASE = ".1.3.6.1.4.1.10876.2"
_OID_HEALTH_STATUS = _OID_HEALTH_BASE + ".2"
_OID_HEALTH_TEXT = _OID_HEALTH_BASE + ".3"

# Sensors table: .1.3.6.1.4.1.10876.2.1.1.1.1, columns 2,3,4,5,6,11,12.
_OID_SENSORS_BASE = ".1.3.6.1.4.1.10876.2.1.1.1.1"
_OID_SENSORS_COLS = ["2", "3", "4", "5", "6", "11", "12"]

# SMART table: .1.3.6.1.4.1.10876.100.1.4.1, columns 1,2,4.
_OID_SMART_BASE = ".1.3.6.1.4.1.10876.100.1.4.1"
_OID_SMART_COLS = ["1", "2", "4"]

_STATE_MAP = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
_SMART_STATUS_MAP = {"0": "OK", "1": "WARN", "2": "CRIT", "3": "UNKNOWN"}
_SMART_LABEL_MAP = {"0": "Healthy", "1": "Warning", "2": "Critical", "3": "Unknown"}

# Status ranking order: [0,1,3,2] -> CRIT(2) worst, then WARN(1), UNKNOWN(3), OK(0)
_STATUS_ORDER = [0, 1, 3, 2]


def _snmp_get(ctx, oid, community, host):
    """Return bare scalar value string, or None if not present (rc!=0)."""
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _snmp_get_raw(ctx, oid, community, host):
    """Return (stdout, rc)."""
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Ov", host, oid],
        mutates=False,
    )
    return res.stdout.strip(), res.rc


def _walk_table(ctx, base, community, host):
    """snmpwalk -Oqn on base; return list of (full_oid, value) pairs."""
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base],
        mutates=False,
    )
    out = []
    if res.rc != 0:
        return out
    for line in res.stdout.splitlines():
        s = line.strip()
        if not s:
            continue
        sp = s.split(" ", 1)
        if len(sp) != 2:
            continue
        out.append((sp[0], sp[1]))
    return out


def _is_supermicro(ctx, community, host):
    sysoid = _snmp_get(ctx, _OID_SYS_OBJID, community, host)
    sysdesc, _ = _snmp_get_raw(ctx, _OID_SYS_DESC, community, host)
    if sysoid == ".1.3.6.1.4.1.311.1.1.3.1.2":
        return True
    if "linux" in sysdesc and _snmp_get(ctx, _OID_FAN1, community, host) != None:
        return True
    return False


def _get_health(ctx, community, host):
    """Return (status_int|None, text|None)."""
    st = _snmp_get(ctx, _OID_HEALTH_STATUS, community, host)
    txt = _snmp_get(ctx, _OID_HEALTH_TEXT, community, host)
    si = None
    if st != None and st.isdigit():
        si = int(st)
    return si, txt


def _get_sensors(ctx, community, host):
    """Walk the sensors table; return list of per-row dicts.
    Columns (SNMPTree oids): 2=name,3=sensor_type,4=reading,5=high,6=low,11=unit,12=dev_status.
    """
    rows = {}
    for col in _OID_SENSORS_COLS:
        oid = _OID_SENSORS_BASE + "." + col
        for full_oid, val in _walk_table(ctx, oid, community, host):
            idx = full_oid[len(oid) + 1:]
            if not idx:
                continue
            r = rows.get(idx)
            if r == None:
                r = {}
                rows[idx] = r
            r[col] = val
    out = []
    for idx, r in rows.items():
        if "2" not in r:
            continue
        out.append({
            "name": r.get("2", ""),
            "sensor_type": r.get("3", ""),
            "reading": r.get("4", ""),
            "high": r.get("5", ""),
            "low": r.get("6", ""),
            "unit": r.get("11", ""),
            "dev_status": r.get("12", ""),
        })
    return out


def _get_smart(ctx, community, host):
    """Walk the SMART table; return list of (serial, name, status) tuples.
    Columns: 1=serial,2=name,4=status.
    """
    rows = {}
    for col in _OID_SMART_COLS:
        oid = _OID_SMART_BASE + "." + col
        for full_oid, val in _walk_table(ctx, oid, community, host):
            idx = full_oid[len(oid) + 1:]
            if not idx:
                continue
            r = rows.get(idx)
            if r == None:
                r = {}
                rows[idx] = r
            r[col] = val
    out = []
    for idx, r in rows.items():
        out.append((r.get("1", ""), r.get("2", ""), r.get("4", "")))
    return out


def _format_smart_item(name):
    return name.replace("\\\\.\\", "")


def _expect_order(values):
    """Reproduces the Checkmk expect_order: returns the max |i - sorted_rank(i)|.
    Non-zero means a boundary was crossed.
    """
    n = len(values)
    if n == 0:
        return 0
    indexed = list(enumerate(values))
    indexed_sorted = sorted(indexed, key=lambda x: x[1])
    worst = 0
    for pos, pair in enumerate(indexed_sorted):
        orig_idx = pair[0]
        d = abs(orig_idx - pos)
        if d > worst:
            worst = d
    return worst


def _worst(*args):
    """Return the worst status value among args using _STATUS_ORDER ranking."""
    worst_val = 0
    for a in args:
        if a in _STATUS_ORDER:
            if _STATUS_ORDER.index(a) > _STATUS_ORDER.index(worst_val):
                worst_val = a
    return _STATE_MAP.get(worst_val, "UNKNOWN")


def _sensor_state(sensor_type, reading_f, high, low, dev_status_i):
    """Return (state, perfvar, perf_reading_f, warn, crit, unit, display)."""
    crit_upper = None
    warn_upper = None
    status_high = 0
    status_low = 0
    if high != "" and high != None:
        crit_upper = float(high)
        warn_upper = crit_upper * 0.95
        status_high = _expect_order([reading_f, warn_upper, crit_upper])
    crit_lower = None
    warn_lower = None
    if low != "" and low != None:
        crit_lower = float(low)
        warn_lower = crit_lower * 1.05
        status_low = _expect_order([crit_lower, warn_lower, reading_f])

    perfvar = None
    display_reading = reading_f
    unit = ""
    if sensor_type == "2":  # Temperature
        unit = "\u00b0C"
        perfvar = "temp"
    elif sensor_type == "1":  # Voltage
        if unit == "mV":
            reading_f = reading_f / 1000.0
            if warn_upper != None:
                warn_upper = warn_upper / 1000.0
            if crit_upper != None:
                crit_upper = crit_upper / 1000.0
            display_reading = reading_f
            unit = "V"
        perfvar = "voltage"
    elif sensor_type == "3":  # Status
        if reading_f == int(reading_f):
            display_reading = "State " + str(int(reading_f))
        else:
            display_reading = str(reading_f)
        unit = ""

    st = _worst(status_high, status_low, dev_status_i)
    return st, perfvar, reading_f, warn_upper, crit_upper, unit, display_reading


def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    item = params.get("item", "")
    discover = params.get("_discover", False)

    # Probe for the real thing: Supermicro detection.
    if not _is_supermicro(ctx, community, host):
        if discover:
            return {"changed": False, "msg": "not a Supermicro system", "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False, "msg": "not a Supermicro system", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = params.get("_section", "supermicro")

    # ---- DISCOVERY ----
    if discover:
        if section == "supermicro":
            st, txt = _get_health(ctx, community, host)
            if st == None:
                return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": [], "host_labels": {"cmk/vendor": "supermicro"}}}
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {
                    "discovery": [{"item": "", "params": {"warn": 1, "crit": 2}, "metrics": []}],
                    "host_labels": {"cmk/vendor": "supermicro"},
                },
            }
        elif section == "supermicro_sensors":
            sensors = _get_sensors(ctx, community, host)
            out = []
            for s in sensors:
                out.append({"item": s["name"], "params": {"warn": 1, "crit": 2}, "metrics": ["sensor_value"]})
            return {
                "changed": False,
                "msg": "discovered %d items" % len(out),
                "data": {"discovery": out, "host_labels": {"cmk/vendor": "supermicro"}},
            }
        elif section == "supermicro_smart":
            smart = _get_smart(ctx, community, host)
            out = []
            for serial, name, status in smart:
                it = _format_smart_item(name)
                out.append({"item": it, "params": {"warn": 1, "crit": 2}, "metrics": []})
            return {
                "changed": False,
                "msg": "discovered %d items" % len(out),
                "data": {"discovery": out, "host_labels": {"cmk/vendor": "supermicro"}},
            }
        return {"changed": False, "msg": "unknown section for discovery", "data": {"discovery": []}}

    # ---- CHECK ----
    if section == "supermicro":
        st, txt = _get_health(ctx, community, host)
        if st == None:
            return {"changed": False, "msg": "health status not available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        state = _STATE_MAP.get(st, "UNKNOWN")
        summary = txt if txt != None else ""
        if not summary:
            summary = "Overall Hardware Health state " + state
        else:
            summary = summary + " (" + state + ")"
        return {"changed": False, "msg": summary, "data": {"state": state, "metrics": {}, "details": ""}}

    elif section == "supermicro_sensors":
        sensors = _get_sensors(ctx, community, host)
        found = None
        for s in sensors:
            if s["name"] == item:
                found = s
                break
        if found == None:
            return {"changed": False, "msg": "no such sensor: " + str(item), "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        reading_f = 0.0
        try_reading = found["reading"]
        if try_reading != "" and try_reading != None:
            if try_reading.lstrip("-").replace(".", "", 1).isdigit():
                reading_f = float(try_reading)
        dev_status_i = 0
        if found["dev_status"] not in ("", None) and found["dev_status"].isdigit():
            dev_status_i = int(found["dev_status"])
        st, perfvar, perf_reading, warn_u, crit_u, unit, display_reading = _sensor_state(
            found["sensor_type"], reading_f, found["high"], found["low"], dev_status_i
        )
        metrics = {}
        if perfvar != None:
            metrics[perfvar] = perf_reading
        summary = str(display_reading) + unit
        return {"changed": False, "msg": summary, "data": {"state": st, "metrics": metrics, "details": ""}}

    elif section == "supermicro_smart":
        smart = _get_smart(ctx, community, host)
        found = None
        for serial, name, status in smart:
            if _format_smart_item(name) == item:
                found = (serial, name, status)
                break
        if found == None:
            return {"changed": False, "msg": "no such SMART device: " + str(item), "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        serial, name, status = found
        state = _SMART_STATUS_MAP.get(status, "UNKNOWN")
        label = _SMART_LABEL_MAP.get(status, "Unknown")
        summary = "(S/N " + str(serial) + ") " + label
        return {"changed": False, "msg": summary, "data": {"state": state, "metrics": {}, "details": ""}}

    return {"changed": False, "msg": "unknown section", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}