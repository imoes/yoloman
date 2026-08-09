OUTLET_STATES = {
    0: ("OK", "off"),
    1: ("OK", "on"),
    2: ("WARN", "off wait"),
    3: ("WARN", "on wait"),
    4: ("CRIT", "off error"),
    5: ("CRIT", "on error"),
    6: ("CRIT", "no comm"),
    7: ("CRIT", "reading"),
    8: ("CRIT", "off fuse"),
    9: ("CRIT", "on fuse"),
}

DEVICE_STATES_V4 = {
    0: ("OK", "normal"),
    1: ("CRIT", "disabled"),
    2: ("CRIT", "purged"),
    5: ("WARN", "reading"),
    6: ("WARN", "settle"),
    7: ("CRIT", "not found"),
    8: ("CRIT", "lost"),
    9: ("CRIT", "read error"),
    10: ("CRIT", "no comm"),
    11: ("CRIT", "pwr error"),
    12: ("CRIT", "breaker tripped"),
    13: ("CRIT", "fuse blown"),
    14: ("CRIT", "low alarm"),
    15: ("WARN", "low warning"),
    16: ("WARN", "high warning"),
    17: ("CRIT", "high alarm"),
    18: ("CRIT", "alarm"),
    19: ("CRIT", "under limit"),
    20: ("CRIT", "over limit"),
    21: ("CRIT", "nvm fail"),
    22: ("CRIT", "profile error"),
    23: ("CRIT", "conflict"),
}

OID_SYS_DESCR = ".1.3.6.1.2.1.1.2.0"
OID_V4_MARKER = ".1.3.6.1.4.1.1718.4"
OID_V3_BASE = ".1.3.6.1.4.1.1718.3.2.3.1"
OID_V4_BASE = ".1.3.6.1.4.1.1718.4.1.8"

def _strip_type(value):
    if value == None:
        return ""
    v = value
    if v.startswith("STRING: "):
        v = v[len("STRING: "):]
    elif v.startswith("INTEGER: "):
        v = v[len("INTEGER: "):]
    elif v.startswith("INTEGER:"):
        v = v[len("INTEGER:"):]
    elif v.startswith("Hex-STRING: "):
        v = v[len("Hex-STRING: "):]
    elif v.startswith("OID: "):
        v = v[len("OID: "):]
    elif v.startswith("Timeticks: "):
        v = v[len("Timeticks: "):]
    elif v.startswith("Counter: "):
        v = v[len("Counter: "):]
    elif v.startswith("Counter32: "):
        v = v[len("Counter32: "):]
    elif v.startswith("Gauge32: "):
        v = v[len("Gauge32: "):]
    if len(v) >= 2 and v[0] == '"' and v[len(v)-1] == '"':
        v = v[1:len(v)-1]
    return v

def main(ctx, params):
    if params.get("_discover"):
        # Detect Sentry PDU by sysDescr OID
        res = ctx.run([
            "snmpget", "-v2c", "-c", params.get("community", "public"),
            "-OvQ", params.get("host", "localhost"), OID_SYS_DESCR
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no sentry pdu found", "data": {"discovery": []}}

        systr = _strip_type(res.stdout).strip()
        v4 = systr == OID_V4_MARKER

        if v4:
            base = OID_V4_BASE
        else:
            base = OID_V3_BASE

        # Walk the outlet entries
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-Oqn", "-fl", params.get("host", "localhost"), base
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no sentry pdu outlets found", "data": {"discovery": []}}

        rows = {}
        for line in res.stdout.splitlines():
            f = line.split()
            if len(f) < 2:
                continue
            oid = f[0]
            if not oid.startswith(base + "."):
                continue
            suffix = oid[len(base)+1:]
            # suffix format: <outlet>.<col> e.g. "1.2"
            parts = suffix.split(".")
            if len(parts) < 2:
                continue
            outlet_str = parts[0]
            col = parts[1]
            val = _strip_type(" ".join(f[1:]))
            if outlet_str not in rows:
                rows[outlet_str] = {}
            rows[outlet_str][col] = val

        discovery = []
        if v4:
            for outlet_id, cols in rows.items():
                outlet_name = cols.get("2.1.3", "")
                outlet_name_stripped = outlet_name.replace("Outlet", "")
                item_name = str(outlet_id) + " " + outlet_name_stripped
                discovery.append({
                    "item": item_name,
                    "params": {},
                    "metrics": [],
                })
        else:
            for outlet_id, cols in rows.items():
                outlet_name = cols.get("3", "")
                outlet_name_stripped = outlet_name.replace("Outlet", "")
                item_name = str(outlet_id) + " " + outlet_name_stripped
                discovery.append({
                    "item": item_name,
                    "params": {},
                    "metrics": [],
                })

        return {
            "changed": False,
            "msg": "discovered %d outlets" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode
    item = params.get("item", "")
    res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-OvQ", params.get("host", "localhost"), OID_SYS_DESCR
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no sentry pdu found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    systr = _strip_type(res.stdout).strip()
    v4 = systr == OID_V4_MARKER

    if v4:
        base = OID_V4_BASE
    else:
        base = OID_V3_BASE

    # Walk to find the outlet matching item
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-Oqn", "-fl", params.get("host", "localhost"), base
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no sentry pdu outlets found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    rows = {}
    for line in res.stdout.splitlines():
        f = line.split()
        if len(f) < 2:
            continue
        oid = f[0]
        if not oid.startswith(base + "."):
            continue
        suffix = oid[len(base)+1:]
        parts = suffix.split(".")
        if len(parts) < 2:
            continue
        outlet_str = parts[0]
        col = parts[1]
        val = _strip_type(" ".join(f[1:]))
        if outlet_str not in rows:
            rows[outlet_str] = {}
        rows[outlet_str][col] = val

    found_state = None
    for outlet_id, cols in rows.items():
        if v4:
            outlet_name = cols.get("2.1.3", "")
            state_col = cols.get("2.1.2", "")
        else:
            outlet_name = cols.get("3", "")
            state_col = cols.get("2", "")
        outlet_name_stripped = outlet_name.replace("Outlet", "")
        item_name = str(outlet_id) + " " + outlet_name_stripped
        if item_name == item:
            if state_col == "":
                found_state = None
            else:
                found_state = int(state_col) if state_col.lstrip("-").isdigit() else None
            break

    if found_state == None:
        return {"changed": False, "msg": "no such outlet: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    states_map = DEVICE_STATES_V4 if v4 else OUTLET_STATES
    if found_state in states_map:
        state, status = states_map[found_state]
        return {"changed": False, "msg": "Status: " + status,
                "data": {"state": state, "metrics": {}, "details": ""}}
    else:
        return {"changed": False, "msg": "Unhandled state: " + str(found_state),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}