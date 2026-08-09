# Starlark translation of checkmk.fortinet_controller_aps — READ-ONLY

# SNMP base + column OIDs (mirrors the Checkmk SNMPSection fetch)
AP_BASE = ".1.3.6.1.4.1.15983.1.1.4.2.1.1"
AP_COLS = ["2", "4", "8", "17", "26", "27"]  # descr, id, location, uptime, oper_state, availability
CLIENT_BASE = ".1.3.6.1.4.1.15983.1.1.3.1.7.1"
CLIENT_COLS = ["5", "9"]                      # client(2.4/5), id

# SysObjectID used for detection
SYS_OBJ_OID = ".1.3.6.1.2.1.1.2.0"
FORTINET_PREFIX = ".1.3.6.1.4.1.15983"

MAP_OPER_STATE = {
    "0": "unknown",
    "1": "enabled",
    "2": "disabled",
    "3": "no license",
    "4": "enabled WN license",
    "5": "power down",
}

MAP_AVAILABILITY = {
    "1": "power off",
    "2": "offline",
    "3": "online",
    "4": "failed",
    "5": "in test",
    "6": "not installed",
}


def _snmpget_str(ctx, host, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _snmpwalk_table(ctx, host, community, base, cols):
    """Walk a table via snmpwalk -Oqn for the first column and return rows.

    Each row: {col_index: value} keyed by the OID suffix after the column base.
    """
    # Walk every column; -Oqn prints: <OID>.<index> <value>
    col_data = []  # list of dicts: index -> value
    ok = True
    for col in cols:
        full_oid = base + "." + col
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, full_oid], mutates=False)
        if res.rc != 0 and res.rc != 2:
            # rc 2 from net-snmp means end-of-mib / no more vars — acceptable
            ok = False
            break
        rows = {}
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid_part = line[:sp]
            val_part = line[sp + 1:]
            idx = oid_part[len(full_oid) + 1:]
            if idx != "":
                rows[idx] = val_part
        col_data.append(rows)
    if not ok or len(col_data) == 0:
        return []
    # Correlate by index across columns
    indices = []
    for rows in col_data:
        for idx in rows.keys():
            if idx not in indices:
                indices.append(idx)
    result = []
    for idx in indices:
        row = {}
        good = True
        for i, rows in enumerate(col_data):
            v = rows.get(idx)
            if v == None:
                good = False
                break
            row[i] = v
        if good:
            result.append(row)
    return result


def _get_uptime(value):
    v = value.strip()
    if v == "" or v == '""':
        return None
    if v.isdigit():
        return int(v)
    # strip surrounding quotes if present
    if v.startswith('"') and v.endswith('"'):
        inner = v[1:-1]
        if inner.isdigit():
            return int(inner)
    return None


def _build_uptime_str(uptime):
    if uptime == None:
        return ""
    if uptime <= 0:
        return "0s"
    days = uptime // 86400
    hours = (uptime % 86400) // 3600
    minutes = (uptime % 3600) // 60
    seconds = uptime % 60
    if days > 0:
        return "%dd %dh %dm" % (days, hours, minutes)
    if hours > 0:
        return "%dh %dm %ds" % (hours, minutes, seconds)
    if minutes > 0:
        return "%dm %ds" % (minutes, seconds)
    return "%ds" % seconds


def _is_fortinet(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    val = _snmpget_str(ctx, host, community, SYS_OBJ_OID)
    if val == None:
        return False
    if val.endswith(FORTINET_PREFIX):
        return True
    return False


def _gather_aps(ctx, params):
    """Gather AP data. Returns list of AP dicts or None if not a Fortinet device."""
    if not _is_fortinet(ctx, params):
        return None
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    ap_rows = _snmpwalk_table(ctx, host, community, AP_BASE, AP_COLS)
    client_rows = _snmpwalk_table(ctx, host, community, CLIENT_BASE, CLIENT_COLS)
    if len(ap_rows) == 0 and len(client_rows) == 0:
        return None

    parsed = {}
    for r in ap_rows:
        descr = r.get(0, "")
        ap_id = r.get(1, "")
        location = r.get(2, "")
        uptime = _get_uptime(r.get(3, ""))
        oper_state = MAP_OPER_STATE.get(r.get(4, ""), "unknown")
        availability = MAP_AVAILABILITY.get(r.get(5, ""), "not installed")
        parsed[ap_id] = {
            "descr": descr,
            "location": location,
            "uptime": uptime,
            "operational": oper_state,
            "availability": availability,
            "clients_count_24": 0,
            "clients_count_5": 0,
        }

    for r in client_rows:
        client = r.get(0, "")
        ap_id = r.get(1, "")
        inst = parsed.get(ap_id)
        if inst == None:
            continue
        if client == "1":
            inst["clients_count_24"] = inst["clients_count_24"] + 1
        elif client == "2":
            inst["clients_count_5"] = inst["clients_count_5"] + 1
    return parsed


def _discover(ctx, params):
    if not _is_fortinet(ctx, params):
        return {"changed": False, "msg": "no Fortinet device detected", "data": {"discovery": []}}
    parsed = _gather_aps(ctx, params)
    if parsed == None:
        return {"changed": False, "msg": "no Fortinet device detected", "data": {"discovery": []}}
    out = []
    for ap_id, values in parsed.items():
        if values["availability"] != "not installed":
            out.append({"item": ap_id, "params": {}, "metrics": ["5ghz_clients", "24ghz_clients", "uptime"]})
    return {"changed": False, "msg": "discovered %d APs" % len(out), "data": {"discovery": out}}


def _check(ctx, params):
    item = params.get("item", "")
    if not _is_fortinet(ctx, params):
        return {"changed": False, "msg": "no Fortinet device detected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "Fortinet device not reachable"}}
    parsed = _gather_aps(ctx, params)
    if parsed == None:
        return {"changed": False, "msg": "no Fortinet device detected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "Fortinet device not reachable"}}
    data = parsed.get(item)
    if data == None:
        return {"changed": False, "msg": "AP %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "AP not found on device"}}

    metrics = {}
    details_lines = []

    # Operational state
    oper_state = data["operational"]
    state = "OK"
    if oper_state == "unknown":
        state = "UNKNOWN"
    elif oper_state in ["disabled", "no license", "power down"]:
        state = "WARN"
    details_lines.append("[%s] Operational: %s" % (data["descr"], oper_state))

    # Availability
    avail_state = data["availability"]
    avail_state_val = "OK"
    if avail_state == "failed":
        avail_state_val = "CRIT"
    elif avail_state in ["power off", "offline", "in test", "not installed"]:
        avail_state_val = "WARN"
    details_lines.append("Availability: %s" % avail_state)

    # Clients
    client_count_24 = data["clients_count_24"]
    client_count_5 = data["clients_count_5"]
    details_lines.append("Connected clients (2.4 ghz/5 ghz): %d/%d" % (client_count_24, client_count_5))
    metrics["5ghz_clients"] = client_count_5
    metrics["24ghz_clients"] = client_count_24

    # Uptime
    uptime = data["uptime"]
    if uptime != None and uptime > 0:
        details_lines.append("Up since " + _build_uptime_str(uptime))
        metrics["uptime"] = uptime

    # Location
    location = data.get("location", "")
    if location != None and location != "":
        details_lines.append("Located at " + location)

    # Combine states: if any is not OK, escalate
    state_priority = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    combined = "OK"
    for s in [state, avail_state_val]:
        if state_priority.get(s, 0) > state_priority.get(combined, 0):
            combined = s

    summary = "; ".join(details_lines)
    return {"changed": False, "msg": summary,
            "data": {"state": combined, "metrics": metrics, "details": "\n".join(details_lines)}}


def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)