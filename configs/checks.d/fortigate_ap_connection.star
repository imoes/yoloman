_STATE_MAP = {
    "0": {"readable": "other", "mon": 3, "description": "The WTP connection state is unknown."},
    "1": {"readable": "offLine", "mon": 1, "description": "The WTP is not connected."},
    "2": {"readable": "onLine", "mon": 0, "description": "The WTP is connected."},
    "3": {"readable": "downloadingImage", "mon": 0, "description": "The WTP is downloading software image from the AC on joining."},
    "4": {"readable": "connectedImage", "mon": 0, "description": "The AC is pushing software image to the connected WTP."},
    "5": {"readable": "standby", "mon": 0, "description": "The WTP is standby on the AC."},
}

_NAME_BASE = ".1.3.6.1.4.1.12356.101.14.4.3.1.3"
_CONN_BASE = ".1.3.6.1.4.1.12356.101.14.4.4.1.7"
_STATION_BASE = ".1.3.6.1.4.1.12356.101.14.4.4.1.17"
_SYSOID = ".1.3.6.1.4.1.12356.101.1"
_DETECT_PREFIX = ".1.3.6.1.2.1.1.2.0"

def _walk(ctx, community, host, base):
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-Oqn", host, base,
    ], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {}
    out = {}
    for line in res.stdout.split("\n"):
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        oid = parts[0]
        if not oid.startswith(base + "."):
            continue
        index = oid[len(base) + 1:]
        out[index] = parts[1].strip().strip('"')
    return out

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    sysid = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv", host, _DETECT_PREFIX,
    ], mutates=False)

    if sysid.rc == 127 or not sysid.stdout or not sysid.stdout.startswith(_SYSOID):
        return {"changed": False, "msg": "no Fortinet device", "data": {"discovery": []}}

    if params.get("_discover"):
        ap_map = _walk(ctx, community, host, _NAME_BASE)
        if not ap_map:
            return {"changed": False, "msg": "no AP names", "data": {"discovery": []}}

        stat_map = _walk(ctx, community, host, _CONN_BASE)
        if not stat_map:
            return {"changed": False, "msg": "no AP connection states", "data": {"discovery": []}}

        discovery = []
        for index, name_val in ap_map.items():
            if stat_map.get(index) == None:
                continue
            if not name_val:
                continue
            discovery.append({"item": name_val, "params": {"warn": 80, "crit": 90}, "metrics": ["connections"]})

        return {
            "changed": False,
            "msg": "discovered %d APs" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")

    ap_map = _walk(ctx, community, host, _NAME_BASE)
    if ap_map == None:
        return {"changed": False, "msg": "no AP names", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    found_index = None
    for index, name_val in ap_map.items():
        if name_val == item:
            found_index = index
            break

    if found_index == None:
        return {"changed": False, "msg": "no AP named %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    conn_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv", host,
        _CONN_BASE + "." + found_index,
    ], mutates=False)
    if conn_res.rc != 0 or not conn_res.stdout:
        return {"changed": False, "msg": "no connection state for %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_code = conn_res.stdout.strip().strip('"')

    station_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv", host,
        _STATION_BASE + "." + found_index,
    ], mutates=False)
    station_count = 0
    if station_res.rc == 0 and station_res.stdout:
        raw = station_res.stdout.strip().strip('"')
        station_count = int(raw) if raw.isdigit() else 0

    state = _STATE_MAP.get(state_code)
    if state == None:
        return {"changed": False, "msg": "unknown connection state code %s for %s" % (state_code, item), "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    return {
        "changed": False,
        "msg": "State: %s, Connected clients: %d" % (state["readable"], station_count),
        "data": {
            "state": state["mon"],
            "metrics": {"connections": station_count},
            "details": state["description"],
        },
    }