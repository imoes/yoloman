_STATE_MAPPING = {
    "mode_disabled": "OK",
    "mode_active_active": "OK",
    "mode_active_passive": "OK",
    "ha_local_state_active": "OK",
    "ha_local_state_passive": "OK",
    "ha_local_state_active_primary": "OK",
    "ha_local_state_active_secondary": "OK",
    "ha_local_state_disabled": "OK",
    "ha_local_state_initial": "WARN",
    "ha_local_state_tentative": "WARN",
    "ha_local_state_non_functional": "CRIT",
    "ha_local_state_suspended": "CRIT",
    "ha_local_state_unknown": "UNKNOWN",
    "ha_peer_state_active": "OK",
    "ha_peer_state_passive": "OK",
    "ha_peer_state_active_primary": "OK",
    "ha_peer_state_active_secondary": "OK",
    "ha_peer_state_disabled": "OK",
    "ha_peer_state_initial": "WARN",
    "ha_peer_state_tentative": "WARN",
    "ha_peer_state_non_functional": "CRIT",
    "ha_peer_state_suspended": "CRIT",
    "ha_peer_state_unknown": "UNKNOWN",
}

_OID_SYS_DESCR = ".1.3.6.1.2.1.1.2.0"
_OID_BASE = ".1.3.6.1.4.1.25461.2.1.2.1"
_OID_COLS = ["1", "11", "12", "13"]

def _uniform(name):
    return name.lower().replace("-", "_")

def _state_for_key(key):
    return _STATE_MAPPING.get(key, "UNKNOWN")

def _worst(states):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    worst = "OK"
    worst_order = 0
    for s in states:
        o = order.get(s, 3)
        if o > worst_order:
            worst = s
            worst_order = o
    return worst

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        descr = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, _OID_SYS_DESCR], mutates=False)
        if descr.rc != 0 or descr.stdout.find("25461") == -1:
            return {"changed": False, "msg": "no Palo Alto device found", "data": {"discovery": []}}
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, _OID_BASE + ".1"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no Palo Alto device found", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {"item": "Palo Alto State", "params": {"warn": 1, "crit": 2}, "metrics": []}
                ],
                "host_labels": {"cmk/dev_type": "palo_alto"}
            },
        }

    values = []
    ok = True
    for col in _OID_COLS:
        r = ctx.run(["snmpget", "-v2c", "-c", community] + [host, _OID_BASE + "." + col], mutates=False)
        if r.rc != 0:
            ok = False
            break
        values.append(r.stdout.strip())

    if not ok or len(values) < 4:
        return {"changed": False, "msg": "Palo Alto device not responding or data unavailable", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    firmware_version = values[0]
    ha_local_state = values[1]
    ha_peer_state = values[2]
    ha_mode = values[3]

    parts = []
    states = []

    mode_key = "mode_" + _uniform(ha_mode)
    mode_state = _state_for_key(mode_key)
    parts.append("HA mode: " + ha_mode)
    states.append(mode_state)

    if ha_mode == "disabled":
        local_state = "OK"
        peer_state = "OK"
    else:
        local_key = "ha_local_state_" + _uniform(ha_local_state)
        peer_key = "ha_peer_state_" + _uniform(ha_peer_state)
        local_state = _state_for_key(local_key)
        peer_state = _state_for_key(peer_key)

    parts.append("HA local state: " + ha_local_state)
    parts.append("HA peer state: " + ha_peer_state)
    states.append(local_state)
    states.append(peer_state)

    overall = _worst(states)
    msg = "Firmware Version: " + firmware_version + "; " + "; ".join(parts)

    return {"changed": False, "msg": msg, "data": {"state": overall, "metrics": {}, "details": msg}}